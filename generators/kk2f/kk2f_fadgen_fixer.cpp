// Compatibility wrapper for the native DELKK FADGEN writer.
//
// DELKKWRITE already writes the complete PYJETS record in the binary format
// consumed by DELSIM.  In particular, status-11 decay records and K(I,3:5)
// mother/daughter indices are physics information needed to retain heavy-
// flavour ancestry.  The historical implementation of this program filtered
// those records and zeroed every relationship.  This implementation therefore
// performs structural validation only and copies every byte unchanged.

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <iostream>
#include <string>
#include <vector>

namespace {

constexpr std::int32_t kCountBytes = 4;
constexpr std::int32_t kParticleBytes = 60;
constexpr std::int32_t kMaxParticles = 4000;
constexpr std::int32_t kMaxRecordBytes = kCountBytes + kMaxParticles * kParticleBytes;

bool fail(const std::string& message, const std::string& temporary_output) {
    std::cerr << "ERROR: " << message << '\n';
    if (!temporary_output.empty()) std::remove(temporary_output.c_str());
    return false;
}

bool copyValidated(const std::string& input_path, const std::string& output_path) {
    if (input_path == output_path) {
        std::cerr << "ERROR: input and output paths must differ\n";
        return false;
    }

    std::ifstream input(input_path.c_str(), std::ios::binary);
    if (!input) {
        std::cerr << "ERROR: cannot open input: " << input_path << '\n';
        return false;
    }

    const std::string temporary_output = output_path + ".tmp";
    std::ofstream output(temporary_output.c_str(), std::ios::binary | std::ios::trunc);
    if (!output) {
        std::cerr << "ERROR: cannot open temporary output: " << temporary_output << '\n';
        return false;
    }

    std::uint64_t events = 0;
    std::uint64_t particles = 0;
    bool saw_terminator = false;

    while (true) {
        std::int32_t leading_marker = 0;
        input.read(reinterpret_cast<char*>(&leading_marker), sizeof leading_marker);
        if (input.gcount() == 0 && input.eof()) break;
        if (!input) return fail("truncated leading record marker", temporary_output);

        // A DELKK event record consists of N followed by N copies of
        // K(5), P(5), V(5): 4 + N * 60 bytes.  N=0 is the optional EOF record.
        if (leading_marker < kCountBytes || leading_marker > kMaxRecordBytes ||
            (leading_marker - kCountBytes) % kParticleBytes != 0) {
            return fail("invalid Fortran record length " + std::to_string(leading_marker),
                        temporary_output);
        }

        std::vector<char> payload(static_cast<std::size_t>(leading_marker));
        input.read(payload.data(), static_cast<std::streamsize>(payload.size()));
        if (!input) return fail("truncated record payload", temporary_output);

        std::int32_t trailing_marker = 0;
        input.read(reinterpret_cast<char*>(&trailing_marker), sizeof trailing_marker);
        if (!input) return fail("missing trailing record marker", temporary_output);
        if (trailing_marker != leading_marker) {
            return fail("Fortran record markers do not match", temporary_output);
        }

        std::int32_t n = 0;
        std::memcpy(&n, payload.data(), sizeof n);
        if (n < 0 || n > kMaxParticles ||
            leading_marker != kCountBytes + n * kParticleBytes) {
            return fail("particle count is inconsistent with record length", temporary_output);
        }
        if (saw_terminator) {
            return fail("data found after N=0 terminator", temporary_output);
        }

        output.write(reinterpret_cast<const char*>(&leading_marker), sizeof leading_marker);
        output.write(payload.data(), static_cast<std::streamsize>(payload.size()));
        output.write(reinterpret_cast<const char*>(&trailing_marker), sizeof trailing_marker);
        if (!output) return fail("failed while writing output", temporary_output);

        if (n == 0) {
            saw_terminator = true;
        } else {
            ++events;
            particles += static_cast<std::uint64_t>(n);
        }
    }

    if (events == 0) return fail("input contains no event records", temporary_output);

    input.close();
    output.close();
    if (!output) return fail("failed while closing output", temporary_output);
    if (std::rename(temporary_output.c_str(), output_path.c_str()) != 0) {
        return fail("cannot install output: " + output_path, temporary_output);
    }

    std::cout << "Validated and copied " << events << " DELKK events (" << particles
              << " PYJETS records) byte-for-byte; decay ancestry preserved\n";
    return true;
}

}  // namespace

int main(int argc, char* argv[]) {
    if (argc != 3) {
        std::cerr << "Usage: " << argv[0] << " <input.fadgen> <output.fadgen>\n";
        return 1;
    }
    return copyValidated(argv[1], argv[2]) ? 0 : 1;
}
