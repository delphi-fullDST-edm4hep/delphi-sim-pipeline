// hepmc2fadgen — generic HepMC3 -> DELPHI FADGEN (fort.26 LUJETS) converter.
//
// Reads a HepMC3 file (any generator) and writes the same Fortran-unformatted
// LUJETS record that `pythia8_generate.cpp`'s EventWriter produces and that
// DELSIM's SXRDLU reads (delsim36.car): per event an int record_size, an int N,
// then for each of N particles K[5] (int32), P[5] (float32), V[5] (float32),
// then a trailing record_size.
//
// Design notes (see recon in the project memory):
//  * Full LUJETS tree is preserved (status + mother/daughter links). Generator-
//    decayed hadrons and tau leptons that keep a daughter in the record are tagged
//    JETSET-native K(,1)=11. This matters: the DELSIM correction cradle
//    (simcra36.car, SXSHST "No ST banks for K(I,1)=21") never places a decay
//    vertex for a K=21 entry, so with the old 21 tag every B/D/tau daughter
//    started at the primary vertex and the simulated sample carried no lifetime
//    (measured 2026-09-04: 0/1514 b hadrons displaced in production). With 11,
//    SXSHST/SXSDK place the decay vertex. Partons, strings, Z/W, beams and
//    documentation entries stay 21.
//  * V[1..4] = production vertex (mm) and time from the HepMC3 record. DELSIM
//    ignores V by default (beam spot from SXBEAP, decay time redrawn from its own
//    VTAU table = flat 1.6 ps for all b hadrons); with the title card
//    `LUDECV TRUE` (run_delsim_only.sh default) SXSDK takes the decay length of a
//    K=11 hadron from |V(first daughter) - V(hadron)|, i.e. the generator's own
//    per-species lifetimes pass through unchanged (verified event by event).
//  * Status is derived from the GENERIC HepMC3 status (1 final / 2 decayed /
//    4 beam) + PDG-based V0 tagging — NOT from any Pythia-specific status code,
//    so the same tool works for Sherpa/Whizard/etc.
//
// Closure target: for Pythia8 input this should reproduce EventWriter's fort.26
// (final-state set + decay tree), modulo benign intermediate status-code labels.

#include "HepMC3/GenEvent.h"
#include "HepMC3/GenParticle.h"
#include "HepMC3/GenVertex.h"
#include "HepMC3/ReaderFactory.h"   // deduce_reader: auto-detect Asciiv3 vs IO_GenEvent
#include "HepMC3/Units.h"

#include <fstream>
#include <iostream>
#include <unordered_map>
#include <vector>
#include <set>
#include <cmath>
#include <string>
#include <algorithm>

using namespace HepMC3;

// V0 set whose Pythia decay is disabled so DELSIM decays them (status -> 4).
// Matches pythia8_generate.cpp exactly: K0_S, Lambda, Sigma-, Sigma+, Xi-, Xi0.
// (NB: Omega 3334 is intentionally NOT here — mirrors the current converter.)
static const std::set<int> kV0AbsPdg = {310, 3122, 3112, 3222, 3312, 3322};

// Mirror of EventWriter::isValidParticle, applied to a HepMC3 particle.
static bool isValidParticle(const ConstGenParticlePtr& p) {
    int abs_pdg = std::abs(p->pid());
    if (abs_pdg == 0) return false;
    if (abs_pdg >= 81 && abs_pdg <= 99) return false;   // JETSET special codes
    if (abs_pdg > 100000) return false;                 // very exotic
    if (abs_pdg >= 20000) return false;                 // modern states

    const FourVector& m = p->momentum();
    const double e = m.e();
    const double mass = p->generated_mass();
    if (e <= 0.0 || mass < 0.0) return false;
    if (!std::isfinite(m.px()) || !std::isfinite(m.py()) ||
        !std::isfinite(m.pz()) || !std::isfinite(e) || !std::isfinite(mass))
        return false;
    if (std::abs(m.px()) > 1000.0 || std::abs(m.py()) > 1000.0 ||
        std::abs(m.pz()) > 1000.0 || e > 1000.0) return false;
    return true;
}

// Generic HepMC3-status -> LUJETS K(,1). V0 PDGs that survive as final state
// become status 4 so DELSIM decays them (matches EventWriter's V0 handling).
//   HepMC3 1 (final) -> 1 (V0 set -> 4) ; generator-decayed hadron/tau with a kept
//   daughter -> 11 ; everything else (beam, partons, strings, Z/W, doc) -> 21.
static int lujetsStatus(int hepmc_status, int pdg, bool has_valid_daughters) {
    // Final-state -> K(,1)=1 (DELSIM tracks it); a V0 that survives to final
    // state -> K(,1)=4 (DELSIM decays it).
    //
    // CRITICAL: do NOT map HepMC3's "decayed" (status 2) to LUJETS K=2 -- in
    // JETSET K(,1)=2 means "final particle, last of a colour-singlet system"
    // (a TRACKED code), so marking a decayed Z / parton as 2 makes DELSIM
    // reject the whole event (reads 0 input events). HepMC3 status numbers and
    // JETSET KS numbers are different namespaces.
    if (hepmc_status == 1) {
        if (kV0AbsPdg.count(std::abs(pdg)) > 0) return 4;
        return 1;
    }
    // Generator-decayed hadrons (|pdg| >= 100, not the V0 set) and tau leptons
    // that keep at least one valid daughter -> JETSET-native 11 ("decayed
    // particle"), so that DELSIM's SXSHST/SXSDK place the decay vertex. An
    // entry tagged 11 MUST keep a daughter: DELSIM's cradle check in SXSDK
    // treats a status-11 entry without daughters as a final particle and
    // prints a FATAL. A decayed V0-set particle stays 21 (DELSIM forces MDCY=0
    // for those and would not displace it; the generator should leave V0s
    // undecayed instead). Partons, strings (91-94, filtered anyway), Z/W,
    // beams (HepMC3 status 4) and documentation entries stay 21.
    const int a = std::abs(pdg);
    const bool hadron_or_tau = (a >= 100 && kV0AbsPdg.count(a) == 0) || a == 15;
    if (hepmc_status != 4 && hadron_or_tau && has_valid_daughters) return 11;
    return 21;
}

class FadgenWriter {
public:
    explicit FadgenWriter(const std::string& filename)
        : events_written_(0), n_k11_(0), n_k11_displaced_(0) {
        out_.open(filename, std::ios::binary);
        if (!out_) { std::cerr << "Error opening " << filename << std::endl; std::exit(1); }
    }
    ~FadgenWriter() {
        if (out_.is_open()) {
            writeEndMarker();
            out_.close();
            std::cout << "Total events written to file: " << events_written_ << std::endl;
            std::cout << "Decayed hadrons tagged K(,1)=11: " << n_k11_
                      << ", of which with a displaced first daughter in the generator record: "
                      << n_k11_displaced_ << std::endl;
            if (n_k11_ > 0 && n_k11_displaced_ == 0)
                std::cerr << "WARNING: the generator record carries NO decay-vertex displacement "
                          << "(all V identical along decay chains). With LUDECV TRUE, DELSIM would "
                          << "place every decay at zero flight distance; run DELSIM with LUDECV=FALSE "
                          << "(its own VTAU lifetimes) for this input." << std::endl;
        }
    }

    // Returns true if the event was written (accepted), false if rejected.
    bool writeEvent(const GenEvent& event, int eventNum) {
        // Stable iteration order = HepMC3 id order (event.particles() is id-sorted).
        const std::vector<ConstGenParticlePtr> all = event.particles();

        // Collect valid particles, then move the incoming BEAM particles
        // (HepMC3 status 4) to the front: DELSIM/JETSET requires the LUJETS
        // record to START with the two incoming beams (e+ e-). The rest keep
        // HepMC3 id order, which is topological (mothers before daughters);
        // since beams have no mother, hoisting them preserves that. Then build
        // the HepMC id -> 1-based output index map over the final order.
        std::vector<ConstGenParticlePtr> valid;
        valid.reserve(all.size());
        for (const auto& p : all)
            if (isValidParticle(p)) valid.push_back(p);
        std::stable_partition(valid.begin(), valid.end(),
            [](const ConstGenParticlePtr& p) { return p->status() == 4; });
        std::unordered_map<int,int> idToOut;
        idToOut.reserve(valid.size());
        for (size_t i = 0; i < valid.size(); ++i)
            idToOut[valid[i]->id()] = static_cast<int>(i + 1);  // 1-based
        const int n = static_cast<int>(valid.size());

        if (n < 2) {
            std::cout << "Event " << eventNum << " REJECTED: only " << n
                      << " valid particles" << std::endl;
            return false;
        }
        if (n > 4000) {
            // DELSIM LUJETS arrays are dimensioned (4000,5) — refuse to overflow.
            std::cerr << "Event " << eventNum << " REJECTED: " << n
                      << " particles exceeds DELSIM's ~4000 cap" << std::endl;
            return false;
        }

        // Walk up the production chain to the first valid ancestor (its 1-based
        // output index), else 0. Mirrors EventWriter::findValidMother.
        auto findValidMother = [&](const ConstGenParticlePtr& p) -> int {
            ConstGenVertexPtr pv = p->production_vertex();
            while (pv) {
                const auto& ins = pv->particles_in();
                if (ins.empty()) break;
                const ConstGenParticlePtr& mother = ins.front();
                auto it = idToOut.find(mother->id());
                if (it != idToOut.end()) return it->second;
                pv = mother->production_vertex();
            }
            return 0;
        };

        // {first,last} 1-based output indices of valid daughters (0,0 if none).
        // Mirrors EventWriter::findValidDaughters.
        auto findValidDaughters = [&](const ConstGenParticlePtr& p) -> std::pair<int,int> {
            int first = 0, last = 0;
            ConstGenVertexPtr ev = p->end_vertex();
            if (ev) {
                for (const auto& d : ev->particles_out()) {
                    auto it = idToOut.find(d->id());
                    if (it == idToOut.end()) continue;
                    const int oi = it->second;
                    if (first == 0 || oi < first) first = oi;
                    if (oi > last) last = oi;
                }
            }
            return {first, last};
        };

        // Require >= 2 final-state (status 1 or 4) particles, like EventWriter.
        int nFinal = 0;
        for (const auto& p : valid) {
            const int k1 = lujetsStatus(p->status(), p->pid(), false);   // 11 vs 21 irrelevant here
            if (k1 == 1 || k1 == 4) ++nFinal;
        }
        if (nFinal < 2) {
            std::cout << "Event " << eventNum << " REJECTED: only " << nFinal
                      << " final-state particles" << std::endl;
            return false;
        }

        // Write the Fortran-unformatted record.
        const int record_size = 4 + n * (5 * 4 + 5 * 4 + 5 * 4);
        out_.write(reinterpret_cast<const char*>(&record_size), 4);
        out_.write(reinterpret_cast<const char*>(&n), 4);

        for (const auto& p : valid) {
            int k[5];
            const std::pair<int,int> kd = findValidDaughters(p);
            k[0] = lujetsStatus(p->status(), p->pid(), kd.first != 0);
            k[1] = p->pid();
            k[2] = findValidMother(p);
            k[3] = kd.first;
            k[4] = kd.second;
            out_.write(reinterpret_cast<const char*>(k), 5 * 4);

            const FourVector& m = p->momentum();
            float pf[5];
            pf[0] = static_cast<float>(m.px());
            pf[1] = static_cast<float>(m.py());
            pf[2] = static_cast<float>(m.pz());
            pf[3] = static_cast<float>(m.e());
            pf[4] = static_cast<float>(p->generated_mass());
            out_.write(reinterpret_cast<const char*>(pf), 5 * 4);

            // V[1..3] = production vertex [mm], V[4] = production time [mm/c], V[5] = 0.
            // Consumed by DELSIM only with the title card LUDECV TRUE (see header note):
            // decay length of a K=11 hadron = |V(first daughter) - V(hadron)|.
            float vf[5] = {0.f, 0.f, 0.f, 0.f, 0.f};
            if (const ConstGenVertexPtr pv = p->production_vertex()) {
                const FourVector& x = pv->position();   // event units are set to GEV/MM in main()
                vf[0] = static_cast<float>(x.x());
                vf[1] = static_cast<float>(x.y());
                vf[2] = static_cast<float>(x.z());
                vf[3] = static_cast<float>(x.t());
            }
            out_.write(reinterpret_cast<const char*>(vf), 5 * 4);

            // Self-check for the LUDECV route: does the generator actually carry decay
            // vertices? Count K=11 hadrons whose first daughter is displaced from them.
            if (k[0] == 11 && std::abs(p->pid()) >= 100) {
                ++n_k11_;
                const ConstGenParticlePtr& d = valid[static_cast<size_t>(kd.first - 1)];
                if (p->production_vertex() && d->production_vertex()) {
                    const FourVector& a = p->production_vertex()->position();
                    const FourVector& b = d->production_vertex()->position();
                    const double dl = std::sqrt((a.x()-b.x())*(a.x()-b.x()) + (a.y()-b.y())*(a.y()-b.y()) + (a.z()-b.z())*(a.z()-b.z()));
                    if (dl > 1e-6) ++n_k11_displaced_;
                }
            }
        }

        out_.write(reinterpret_cast<const char*>(&record_size), 4);
        ++events_written_;

        std::cout << "Event " << eventNum << " ACCEPTED: " << n << " particles ("
                  << nFinal << " final)" << std::endl;
        return true;
    }

private:
    void writeEndMarker() {
        const int record_size = 4;
        const int zero = 0;
        out_.write(reinterpret_cast<const char*>(&record_size), 4);
        out_.write(reinterpret_cast<const char*>(&zero), 4);
        out_.write(reinterpret_cast<const char*>(&record_size), 4);
    }

    std::ofstream out_;
    int events_written_;
    long n_k11_;            // decayed hadrons written with K(,1)=11
    long n_k11_displaced_;  // ... whose first daughter's production vertex differs from theirs
};

int main(int argc, char* argv[]) {
    if (argc < 2) {
        std::cerr << "Usage: " << argv[0] << " <input.hepmc> [output=fort.26]\n";
        return 1;
    }
    const std::string infile = argv[1];
    const std::string outfile = (argc > 2) ? argv[2] : "fort.26";

    // deduce_reader auto-detects the HepMC3 ASCII variant so the converter stays
    // generator-agnostic: Asciiv3 (Pythia8, Sherpa) and IO_GenEvent/HepMC2 (Herwig)
    // are both handled without the caller knowing which generator produced the file.
    auto reader = deduce_reader(infile);
    if (!reader || reader->failed()) {
        std::cerr << "Error: cannot open/parse HepMC3 input " << infile << std::endl;
        return 1;
    }

    FadgenWriter writer(outfile);

    int read = 0, accepted = 0;
    while (!reader->failed()) {
        GenEvent evt(Units::GEV, Units::MM);
        reader->read_event(evt);
        if (reader->failed()) break;      // clean EOF or error after last event
        evt.set_units(Units::GEV, Units::MM);
        ++read;
        if (writer.writeEvent(evt, read)) ++accepted;
    }
    reader->close();

    std::cout << "\nSummary: read " << read << " events, accepted " << accepted
              << " (" << (read - accepted) << " rejected)" << std::endl;
    return 0;
}
