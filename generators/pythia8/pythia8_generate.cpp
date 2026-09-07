#include "Pythia8/Pythia.h"
#include <fstream>
#include <iostream>
#include <iomanip>
#include <cmath>
#include <cstdlib>
#include <ctime>
#include <unistd.h>
#include <unordered_map>
#include <set>
#include <sstream>
#include <string>
#include <algorithm>
#include <cctype>
#include <memory>

using namespace Pythia8;

// Opt-in veto of events containing specific |PDG| (e.g. unwanted B-hadrons).
// Uses the Pythia 8.31x UserHooks API (canVetoAfterHadronization /
// doVetoAfterHadronization, const Event&) — key4hep's Pythia 8.315 does NOT
// expose the older canVetoEvent/doVetoEvent. Fires after hadronization, where
// the hadrons exist in the record. EMPTY set = no veto (hook not registered).
class VetoUnwantedBHadrons : public UserHooks {
public:
    explicit VetoUnwantedBHadrons(std::set<int> vetoAbsPdgs)
        : vetoAbsPdgs_(std::move(vetoAbsPdgs)) {}
    bool canVetoAfterHadronization() override { return !vetoAbsPdgs_.empty(); }
    bool doVetoAfterHadronization(const Event &event) override {
        for (int i = 1; i < event.size(); ++i)
            if (vetoAbsPdgs_.count(std::abs(event[i].id())) > 0) return true;
        return false;
    }
private:
    std::set<int> vetoAbsPdgs_;
};

// Parse a comma-separated |PDG| list into `out`. CLEARS `out` first (so a
// caller default is never silently unioned in), and an empty/blank string
// leaves it empty = veto disabled.
static void parseCsvPdgs(const std::string &text, std::set<int> &out) {
    out.clear();
    std::stringstream ss(text);
    std::string tok;
    while (std::getline(ss, tok, ',')) {
        tok.erase(std::remove_if(tok.begin(), tok.end(), ::isspace), tok.end());
        if (tok.empty()) continue;
        const int pdg = std::atoi(tok.c_str());
        if (pdg != 0) out.insert(std::abs(pdg));
    }
}

class EventWriter {
private:
    std::ofstream outfile;
    int events_written;

    // This is temperary, might not be correct. 
    int convertToJetsetStatus(int pythia8_status, int pdg_id, int mother_id) {
        int status;
        
        if (pythia8_status > 0) {
            // Any final-state photon (positive Pythia status => isFinal) is
            // tracked as K(I,1)=1 so DELSIM propagates it through GEANT3, keeping
            // visible-energy bookkeeping consistent. The previous version only
            // rescued shower photons (status 41-60); final photons with other
            // statuses (notably status 63, beam-remnant/primordial-kT stage,
            // ~2/event) fell through the 21-80 -> status=2 catch-all and were
            // silently dropped -> phantom missing energy. Confirmed via
            // photon_diag + the hepmc2fadgen closure test (2026-06-06).
            if (abs(pdg_id) == 22) {
                status = 1;
            }
            // Status 23: outgoing from hard process
            else if (pythia8_status == 23) {
                int abs_pdg = abs(pdg_id);
                if (abs_pdg == 11 || abs_pdg == 13 ||
                    abs_pdg == 12 || abs_pdg == 14 || abs_pdg == 16) {
                    status = 1;
                } else {
                    status = 2;
                }
            }
            // Status 51-60 non-photon: accept recoiled charged leptons after
            // FSR (the photon case is already handled above). A lepton with a
            // photon mother is a γ -> ℓℓ conversion product; skip those.
            else if (pythia8_status >= 51 && pythia8_status <= 60) {
                int abs_pdg = abs(pdg_id);
                int abs_mother = abs(mother_id);
                if ((abs_pdg == 11 || abs_pdg == 13) && abs_mother != 22) {
                    status = 1;
                } else {
                    status = 21;
                }
            }
            else if (pythia8_status >= 81 && pythia8_status <= 99) status = 1;
            else if (pythia8_status >= 21 && pythia8_status <= 80) status = 2;
            else if (pythia8_status >= 11 && pythia8_status <= 20) status = 11;
            else status = 21;
        } else {
            status = 21;
        }
        
        // V0 handling — match kk2f_fadgen_fixer.cpp isV0Particle().
        // K0L (130) is detector-stable (ctau ~ 15.3 m, P(decay in tracker)
        // ~1%) and must NOT be V0-tagged. Sigma+/- and Xi- have ctau of
        // a few cm and DO need V0 treatment so DELSIM decays them.
        if (status == 1) {
            int abs_pdg = abs(pdg_id);
            if (abs_pdg == 310  ||   // K0_S
                abs_pdg == 3122 ||   // Lambda
                abs_pdg == 3112 ||   // Sigma-
                abs_pdg == 3222 ||   // Sigma+
                abs_pdg == 3312 ||   // Xi-
                abs_pdg == 3322) {   // Xi0
                return 4;
            }
        }
        
        return status;
    }
    
    bool isValidParticle(const Particle& p) {
        // Check PDG code validity
        int abs_pdg = abs(p.id());
        if (abs_pdg == 0) return false;
        if (abs_pdg >= 81 && abs_pdg <= 99) return false;  // JETSET special codes
        if (abs_pdg > 100000) return false;                // Very exotic particles

	if (abs_pdg >= 20000) return false;  // Modern states
        
        // Check kinematics
        if (p.e() <= 0.0 || p.m() < 0.0) return false;
        if (!std::isfinite(p.px()) || !std::isfinite(p.py()) || 
            !std::isfinite(p.pz()) || !std::isfinite(p.e()) || 
            !std::isfinite(p.m())) return false;
        
        // Check reasonable momentum range (reject extreme values)
        if (std::abs(p.px()) > 1000.0 || std::abs(p.py()) > 1000.0 || 
            std::abs(p.pz()) > 1000.0 || p.e() > 1000.0) return false;
        
        return true;
    }
    
    bool hasMinimumFinalState(const Event& event) {
        int nFinal = 0;
        
        for (int i = 1; i < event.size(); ++i) {
            const Particle& p = event[i];
            
            if (p.status() <= 0) continue;  // Skip intermediate/negative status
            if (!isValidParticle(p)) continue;
            
            // Get mother PDG ID
            int mother_pdg = 0;
            if (p.mother1() > 0 && p.mother1() < event.size()) {
                mother_pdg = event[p.mother1()].id();
            }
            
            // Check what JETSET status this would get
            int jetset_status = convertToJetsetStatus(p.status(), p.id(), mother_pdg);
            
            // Count only final state particles (status 1 or 4)
            if (jetset_status == 1 || jetset_status == 4) {
                nFinal++;
            }
        }
        
        return nFinal >= 2;
    }
    
public:
    EventWriter(const std::string& filename) : events_written(0) {
        outfile.open(filename, std::ios::binary);
        if (!outfile) {
            std::cerr << "Error opening " << filename << std::endl;
            exit(1);
        }
    }
    
    ~EventWriter() {
        if (outfile.is_open()) {
            writeEndMarker();
            outfile.close();
            std::cout << "Total events written to file: " << events_written << std::endl;
        }
    }
    
    bool writeEvent(const Event& event, int eventNum) {
        // Pre-validate event has minimum particles
        if (!hasMinimumFinalState(event)) {
            std::cout << "Event " << eventNum << " REJECTED: Too few final state particles" << std::endl;
            return false;
        }
        
        std::vector<int> validParticles;
        
        // Collect valid particles
        for (int i = 1; i < event.size(); ++i) {
            const Particle& p = event[i];
            
            if (p.status() == 0) continue;  // Skip empty entries
            if (!isValidParticle(p)) continue;
            
            validParticles.push_back(i);
        }
        
        int n = validParticles.size();

        // Build mapping from Pythia8 event index to 1-based output index.
        // Used to translate mother/daughter references after filtering.
        std::unordered_map<int, int> indexMap;
        indexMap.reserve(n);
        for (int i = 0; i < n; ++i) {
            indexMap[validParticles[i]] = i + 1;
        }

        // Walk up the mother chain until we find a particle that survived the
        // filter; return its 1-based output index, or 0 if none is found.
        const int eventSize = static_cast<int>(event.size());
        auto findValidMother = [&](int idx) -> int {
            int m = event[idx].mother1();
            while (m > 0 && m < eventSize) {
                auto it = indexMap.find(m);
                if (it != indexMap.end()) return it->second;
                m = event[m].mother1();
            }
            return 0;
        };

        // Collect all valid daughters and return the {first, last} 1-based
        // output indices (both 0 when the particle has no valid daughters).
        auto findValidDaughters = [&](int idx) -> std::pair<int, int> {
            const std::vector<int> dList = event[idx].daughterList();
            int first = 0, last = 0;
            for (int d : dList) {
                auto it = indexMap.find(d);
                if (it != indexMap.end()) {
                    if (first == 0 || it->second < first) first = it->second;
                    if (it->second > last) last = it->second;
                }
            }
            return {first, last};
        };

        // Ensure we have enough particles for DELSIM
        if (n < 2) {
            std::cout << "Event " << eventNum << " REJECTED: Only " << n << " valid particles" << std::endl;
            return false;
        }
        
        // Count different particle types for validation
        int nFinal = 0, nIntermediate = 0, nBeam = 0, nV0 = 0, nFSRgamma = 0;
        for (int idx : validParticles) {
            int mother_pdg = 0;
            if (event[idx].mother1() > 0 && event[idx].mother1() < event.size()) {
                mother_pdg = event[event[idx].mother1()].id();
            }

            int status = convertToJetsetStatus(event[idx].status(), event[idx].id(), mother_pdg);
            if (status == 1) nFinal++;
            else if (status == 2 || status == 11) nIntermediate++;
            else if (status == 21) nBeam++;
            else if (status == 4) nV0++;

            // FSR photon off a charged lepton, now kept as final state.
            if (status == 1 && event[idx].id() == 22) {
                int abs_mother = abs(mother_pdg);
                if (abs_mother == 11 || abs_mother == 13 || abs_mother == 15) {
                    nFSRgamma++;
                }
            }
        }
        
        // Ensure we have final state particles (DELSIM needs these)
        if (nFinal < 2) {
            std::cout << "Event " << eventNum << " REJECTED: Only " << nFinal << " final state particles" << std::endl;
            return false;
        }
        
        std::cout << "Event " << eventNum << " ACCEPTED: " << n << " particles ("
                 << nFinal << " final, " << nIntermediate << " intermediate, "
                 << nBeam << " beam, " << nV0 << " V0, "
                 << nFSRgamma << " FSR-γ from ℓ)" << std::endl;
        
        // Write the event
        int record_size = 4 + n * (5*4 + 5*4 + 5*4);
        
        outfile.write(reinterpret_cast<const char*>(&record_size), 4);
        outfile.write(reinterpret_cast<const char*>(&n), 4);
        
        for (int idx : validParticles) {
            const Particle& p = event[idx];

            int mother_pdg = 0;
            if (p.mother1() > 0 && p.mother1() < event.size()) {
                mother_pdg = event[p.mother1()].id();
            }
            
            // K array
            int k[5];
            k[0] = convertToJetsetStatus(p.status(), p.id(), mother_pdg);
            k[1] = p.id();
            k[2] = findValidMother(idx);
            std::pair<int,int> kd = findValidDaughters(idx);
            k[3] = kd.first;
            k[4] = kd.second;
            
            outfile.write(reinterpret_cast<const char*>(k), 5*4);
            
            // P array as float32
            float p_array[5];
            p_array[0] = static_cast<float>(p.px());
            p_array[1] = static_cast<float>(p.py());
            p_array[2] = static_cast<float>(p.pz());
            p_array[3] = static_cast<float>(p.e());
            p_array[4] = static_cast<float>(p.m());
            
            outfile.write(reinterpret_cast<const char*>(p_array), 5*4);
            
            // V array as float32
            float v_array[5];
            v_array[0] = 0.0f;  // Simplified vertex (set to origin)
            v_array[1] = 0.0f;
            v_array[2] = 0.0f;
            v_array[3] = 0.0f;
            v_array[4] = 0.0f;
            
            outfile.write(reinterpret_cast<const char*>(v_array), 5*4);
        }
        
        outfile.write(reinterpret_cast<const char*>(&record_size), 4);
        events_written++;
        
        return true;
    }
    
private:
    void writeEndMarker() {
        int record_size = 4;
        int n = 0;
        outfile.write(reinterpret_cast<const char*>(&record_size), 4);
        outfile.write(reinterpret_cast<const char*>(&n), 4);
        outfile.write(reinterpret_cast<const char*>(&record_size), 4);
    }
};

int main(int argc, char* argv[]) {
    // Parse command line arguments
    int target_events = 20;  // Default value
    std::string config_file = "";  // Default: no config file
    
    // Parse arguments: [events] [config_file]
    if (argc > 1) {
        target_events = std::atoi(argv[1]);
        if (target_events <= 0) {
            std::cerr << "Error: Number of events must be positive" << std::endl;
            std::cerr << "Usage: " << argv[0] << " [number_of_events] [config_file] [veto_pdg_csv]" << std::endl;
            return 1;
        }
    }

    if (argc > 2) {
        config_file = argv[2];
    }

    // [veto_pdg_csv] is OPT-IN: empty/absent = NO veto. Pass e.g. "541" to veto
    // events that contain a Bc. Cleared-then-parsed (no silent default), and an
    // empty string disables it. The hook is only registered below if non-empty.
    std::set<int> vetoAbsPdgs;
    if (argc > 3) parseCsvPdgs(argv[3], vetoAbsPdgs);
    
    // Generate unique random seed for each run (constrained to Pythia8 limits)
    unsigned long raw_seed = static_cast<unsigned long>(std::time(nullptr)) + static_cast<unsigned long>(getpid());
    unsigned long seed = raw_seed % 900000000;  // Keep within Pythia8's seed range
    
    Pythia pythia;
    
    std::cout << "PYTHIA 8 with Enhanced Event Validation" << std::endl;
    std::cout << "=======================================" << std::endl;
    std::cout << "Random seed: " << seed << std::endl;
    std::cout << "Target events: " << target_events << std::endl;
    if (!config_file.empty()) {
        std::cout << "Config file: " << config_file << std::endl;
    }
    
    // Set random seed
    pythia.readString("Random:setSeed = on");
    pythia.readString("Random:seed = " + std::to_string(seed));
    
    // Load configuration file if provided
    if (!config_file.empty()) {
        std::ifstream config(config_file);
        if (!config) {
            std::cerr << "Error: Cannot open config file " << config_file << std::endl;
            return 1;
        }
        
        std::string line;
        int line_num = 0;
        std::cout << "Loading configuration from " << config_file << ":" << std::endl;
        
        while (std::getline(config, line)) {
            line_num++;
            
            // Skip empty lines and comments
            if (line.empty() || line[0] == '#' || line[0] == '!') continue;
            
            // Trim whitespace
            size_t start = line.find_first_not_of(" \t");
            size_t end = line.find_last_not_of(" \t");
            if (start == std::string::npos) continue;
            line = line.substr(start, end - start + 1);
            
            std::cout << "  " << line << std::endl;
            
            if (!pythia.readString(line)) {
                std::cerr << "Warning: Config file line " << line_num 
                         << " not understood: " << line << std::endl;
            }
        }
        config.close();
    } else {
        // Default PYTHIA 8 configuration (when no config file provided)
        std::cout << "Using default configuration:" << std::endl;
        
        pythia.readString("Beams:idA = 11");
        pythia.readString("Beams:idB = -11");
        pythia.readString("Beams:eCM = 91.187");
        
        pythia.readString("WeakSingleBoson:ffbar2gmZ = on");
        pythia.readString("23:onMode = off");
        pythia.readString("23:onIfAny = 1 2 3 4 5");  // Hadronic decays only
        
        pythia.readString("PartonLevel:ISR = on");
        pythia.readString("PartonLevel:FSR = on");
        pythia.readString("HadronLevel:all = on");
        
        std::cout << "  e+e- -> Z -> hadrons at 91.187 GeV" << std::endl;
        std::cout << "  ISR/FSR enabled, hadronic decays only" << std::endl;
    }
    
    // ============================================
    // DISABLE V0 PARTICLE DECAYS
    // ============================================
    std::cout << "Disabling V0 particle decays:" << std::endl;
    
    // Disable K0_S decay (PDG ID: 310)
    pythia.readString("310:mayDecay = false");
    std::cout << "  K0_S (310) decay disabled" << std::endl;
    
    // Disable Lambda decay (PDG ID: 3122)
    pythia.readString("3122:mayDecay = false");
    std::cout << "  Lambda (3122) decay disabled" << std::endl;
    
    // Disable Anti-Lambda decay (PDG ID: -3122)  
    pythia.readString("-3122:mayDecay = false");
    std::cout << "  Anti-Lambda (-3122) decay disabled" << std::endl;
    
    // Disable Xi0 decay (PDG ID: 3322)
    pythia.readString("3322:mayDecay = false");
    std::cout << "  Xi0 (3322) decay disabled" << std::endl;
    
    // Disable Anti-Xi0 decay (PDG ID: -3322)
    pythia.readString("-3322:mayDecay = false");
    std::cout << "  Anti-Xi0 (-3322) decay disabled" << std::endl;

    // Disable Sigma- decay (PDG ID: 3112) and its antiparticle.
    // ctau(Sigma-) ~ 4.4 cm — short enough that Pythia decays it by default,
    // but in DELPHI it should be V0-tagged so DELSIM handles the decay.
    pythia.readString("3112:mayDecay = false");
    pythia.readString("-3112:mayDecay = false");
    std::cout << "  Sigma- (3112 / -3112) decay disabled" << std::endl;

    // Disable Sigma+ decay (PDG ID: 3222) and its antiparticle.
    // ctau(Sigma+) ~ 2.4 cm.
    pythia.readString("3222:mayDecay = false");
    pythia.readString("-3222:mayDecay = false");
    std::cout << "  Sigma+ (3222 / -3222) decay disabled" << std::endl;

    // Disable Xi- decay (PDG ID: 3312) and its antiparticle.
    // ctau(Xi-) ~ 4.9 cm.
    pythia.readString("3312:mayDecay = false");
    pythia.readString("-3312:mayDecay = false");
    std::cout << "  Xi- (3312 / -3312) decay disabled" << std::endl;

    // Register the B-hadron veto ONLY when an explicit non-empty PDG set was
    // given (opt-in). With no veto_pdg_csv the hook is never attached, so the
    // default run is unbiased.
    std::shared_ptr<VetoUnwantedBHadrons> vetoHook;
    if (!vetoAbsPdgs.empty()) {
        vetoHook = std::make_shared<VetoUnwantedBHadrons>(vetoAbsPdgs);
        pythia.setUserHooksPtr(vetoHook);
        std::cout << "B-hadron veto ON — rejecting events with |PDG| in:";
        for (int p : vetoAbsPdgs) std::cout << " " << p;
        std::cout << std::endl;
    }

    if (!pythia.init()) {
        std::cerr << "PYTHIA initialization failed!" << std::endl;
        return -1;
    }

    EventWriter writer("fort.26");
    
    int events_generated = 0;  // Count how many PYTHIA generated
    int events_accepted = 0;   // Count how many we accepted

    // [max_attempt_factor] bounds the retry budget as target_events * factor.
    // The historical value of 3 is right for an UNBIASED run, where nearly
    // every generated event is accepted. It is far too small once the veto
    // hook is enabled: enriching a B_s pair sample accepts ~0.98% of Z->bb
    // events, i.e. ~102 attempts per kept event, so a 3x budget quietly writes
    // ~3% of what was asked for instead of failing. Configurable so the
    // unbiased default is unchanged.
    int attempt_factor = 3;
    if (argc > 4) {
        const int f = std::atoi(argv[4]);
        if (f > 0) attempt_factor = f;
    }
    const long max_attempts = static_cast<long>(target_events) * attempt_factor;

    std::cout << "Attempting to generate " << target_events << " validated events..." << std::endl;
    std::cout << "Attempt budget: " << max_attempts
              << " (" << attempt_factor << "x target)" << std::endl;

    long attempt = 0;
    for (; attempt < max_attempts && events_accepted < target_events; ++attempt) {
        if (!pythia.next()) {
            std::cout << "PYTHIA generation failed on attempt " << (attempt + 1) << std::endl;
            continue;
        }
        
        events_generated++;
        
        if (writer.writeEvent(pythia.event, events_generated)) {
            events_accepted++;
        }
        
        // Show progress
        if (events_accepted % 10 == 0 && events_accepted > 0) {
            std::cout << "Progress: " << events_accepted << "/" << target_events 
                     << " events accepted (from " << events_generated << " generated)" << std::endl;
        }
    }
    
    std::cout << std::endl;
    std::cout << "Final summary:" << std::endl;
    std::cout << "  PYTHIA events generated: " << events_generated << std::endl;
    std::cout << "  Events accepted for DELSIM: " << events_accepted << std::endl;
    if (events_generated > 0) {
        std::cout << "  Rejection rate: " << std::fixed << std::setprecision(1) 
                  << (100.0 * (events_generated - events_accepted) / events_generated) << "%" << std::endl;
    }
    std::cout << "  Attempts used: " << attempt << " / " << max_attempts << std::endl;
    if (attempt > 0) {
        std::cout << "  Acceptance: " << std::fixed << std::setprecision(3)
                  << (100.0 * events_accepted / attempt) << "%" << std::endl;
    }

    // Fail closed on a shortfall. A short fort.26 is not a smaller sample, it
    // is a WRONG one: the DELSIM stage and the campaign gates downstream both
    // expect exactly the requested event count, and a silent shortfall would
    // only be caught much later, after the expensive simulation had run.
    if (events_accepted < target_events) {
        std::cerr << std::endl
                  << "ERROR: only " << events_accepted << " of " << target_events
                  << " events accepted after " << attempt << " attempts." << std::endl;
        std::cerr << "       Raise the attempt factor (currently " << attempt_factor
                  << ") via MAX_ATTEMPT_FACTOR." << std::endl;
        if (attempt > 0) {
            const double acc = static_cast<double>(events_accepted) / attempt;
            if (acc > 0) {
                std::cerr << "       Measured acceptance " << std::fixed
                          << std::setprecision(3) << (100.0 * acc)
                          << "% implies a factor of at least "
                          << static_cast<long>(2.0 / acc) << "." << std::endl;
            }
        }
        return 1;
    }

    return 0;
}
