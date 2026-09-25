#pragma once
#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdint>

namespace ongaku {
// One control-thread writer, one audio-thread reader. All fields are atomic:
// the bounded snapshot has no C++ data race and never spins on the audio thread.
class HandoffEnvelope {
    static_assert(std::atomic<uint64_t>::is_always_lock_free);
    static_assert(std::atomic<double>::is_always_lock_free);
    struct Command {
        uint64_t version = 0, host = 0, frames = 0, destination = 0;
        double sample = 0;
    };
    std::atomic<uint64_t> sequence{0}, host{0}, frames{0}, destination{0}, completed{0};
    std::atomic<double> sample{0};
    Command previous; // audio thread only

    void publish(uint64_t input, uint64_t startHost, double startSample, uint64_t count) noexcept {
        sequence.fetch_add(1);
        destination.store(input);
        host.store(startHost);
        sample.store(startSample);
        frames.store(count);
        sequence.fetch_add(1);
    }
public:
    void select(uint64_t input) noexcept { publish(input & 1, 0, 0, 0); }
    void schedule(uint64_t input, uint64_t startHost, double startSample, uint64_t count) noexcept {
        publish(input & 1, startHost, startSample, std::max(uint64_t(1), count));
    }
    bool isComplete() const noexcept {
        const auto version = sequence.load();
        return version != 0 && !(version & 1) && completed.load() == version;
    }
    struct Block {
        uint64_t version, duration, destination;
        double firstFrame;
        float newGain(uint32_t frame) const noexcept {
            if (duration == 0) return 1;
            return static_cast<float>(std::clamp((firstFrame + frame) / double(duration), 0.0, 1.0));
        }
        bool needsInput(uint64_t input, uint32_t count) const noexcept {
            if (input == destination) return newGain(count - 1) > 0;
            return newGain(0) < 1;
        }
    };
    Block begin(uint64_t nowHost, bool hostValid, double nowSample, bool sampleValid,
                double rate, double secondsPerTick) noexcept {
        // Default sequential consistency intentionally keeps the seqlock's
        // publication ordering simple. At most two snapshots per render block.
        for (int attempt = 0; attempt < 2; ++attempt) {
            const auto before = sequence.load();
            if (before & 1) continue;
            Command candidate{before, host.load(), frames.load(), destination.load(), sample.load()};
            if (sequence.load() == before) { previous = candidate; break; }
        }
        // Once settled, a missing/rebased timestamp must not resurrect the old
        // source. Only a new control command may change the selected input.
        if (completed.load() == previous.version && previous.frames > 0)
            return {previous.version, previous.frames, previous.destination, double(previous.frames)};
        double elapsed = -1e30; // invalid timestamps retain the original input
        if (hostValid) {
            const double delta = nowHost >= previous.host ? double(nowHost - previous.host)
                                                         : -double(previous.host - nowHost);
            elapsed = std::round(delta * secondsPerTick * rate);
        } else if (sampleValid) {
            elapsed = nowSample - previous.sample;
        }
        return {previous.version, previous.frames, previous.destination, elapsed};
    }
    void finish(const Block &block, uint32_t count) noexcept {
        if (count > 0 && block.newGain(count - 1) >= 1) completed.store(block.version);
    }
};
} // namespace ongaku
