#include "../audio/HandoffMixerDSP.hpp"
#include <thread>
#include <cstdio>
#include <cstdlib>

int main() {
    ongaku::HandoffEnvelope envelope;
    std::atomic<bool> done{false};
    std::thread writer([&] {
        for (uint64_t i = 0; i < 100000; ++i) {
            if (i % 3 == 0) envelope.select(i & 1);
            else envelope.schedule(i & 1, i * 100, double(i), 6144);
        }
        done.store(true);
    });
    uint64_t position = 0;
    do {
        const auto block = envelope.begin(position * 100, true, double(position), true, 96000, 1e-9);
        if (block.destination > 1 || !std::isfinite(block.firstFrame)) std::abort();
        for (unsigned frame : {0u, 127u, 511u}) {
            const float gain = block.newGain(frame);
            if (!std::isfinite(gain) || gain < 0 || gain > 1) std::abort();
        }
        envelope.finish(block, 512);
        ++position;
    } while (!done.load());
    writer.join();
    envelope.select(1);
    const auto settled = envelope.begin(0, false, 0, false, 96000, 1e-9);
    if (settled.destination != 1 || settled.newGain(0) != 1) std::abort();
    puts("PASS: 100000 concurrent control commands, bounded audio snapshots and final selection");
}
