#import "../audio/HandoffMixerAudioUnit.h"
#include "../audio/HandoffMixerDSP.hpp"
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <vector>
#include <mach/mach_time.h>

static void check(bool value, const char *message) {
    if (!value) { fprintf(stderr, "FAIL: %s\n", message); exit(1); }
}

static void renderCheck(double rate, bool useHostTime, bool identical, unsigned destination) {
    AVAudioUnitEffect *node = [OngakuHandoffMixer makeNode];
    check([node.AUAudioUnit isKindOfClass:OngakuHandoffMixer.class], "registered mixer instance");
    OngakuHandoffMixer *unit = (OngakuHandoffMixer *)node.AUAudioUnit;
    NSError *error = nil;
    AVAudioFormat *format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:rate channels:2];
    for (AUAudioUnitBus *bus in unit.inputBusses) check([bus setFormat:format error:&error], "input format");
    check([unit.outputBusses[0] setFormat:format error:&error], "output format");
    unit.maximumFramesToRender = 1024;
    check([unit allocateRenderResourcesAndReturnError:&error], "allocate resources");
    [unit selectInput:1 - destination];
    const uint64_t start = 1537, duration = uint64_t(std::round(rate * 0.064));
    const uint64_t hostBase = mach_absolute_time();
    [unit scheduleInput:destination atHostTime:hostBase + [AVAudioTime hostTimeForSeconds:double(start) / rate]
           atSampleTime:start durationFrames:duration];
    const auto render = unit.internalRenderBlock;
    __block unsigned oldPullsAfterEnd = 0;
    AURenderPullInputBlock pull = ^AUAudioUnitStatus(AudioUnitRenderActionFlags *flags, const AudioTimeStamp *time,
                                                   AUAudioFrameCount count, NSInteger bus, AudioBufferList *data) {
        if (bus == 1 - destination && time->mSampleTime >= start + duration) ++oldPullsAfterEnd;
        for (unsigned ch = 0; ch < 2; ++ch) {
            float *out = static_cast<float *>(data->mBuffers[ch].mData);
            for (unsigned i = 0; i < count; ++i) {
                const float signal = float(0.7 * sin(2 * M_PI * 997 * (time->mSampleTime + i) / rate));
                out[i] = signal * (ch == 0 ? 1 : -0.6f) * (identical || bus == 0 ? 1 : -1);
            }
        }
        return noErr;
    };
    unsigned chunks[] = {1, 127, 512, 33, 1024, 256};
    uint64_t position = 0;
    size_t iteration = 0;
    double largestError = 0;
    // No main-loop pumping or gain updates for the entire transition.
    while (position < start + duration + 4096) {
        const unsigned count = chunks[iteration++ % 6];
        AudioTimeStamp time = {};
        time.mSampleTime = double(position);
        time.mHostTime = hostBase + [AVAudioTime hostTimeForSeconds:double(position) / rate];
        time.mFlags = kAudioTimeStampSampleTimeValid | (useHostTime ? kAudioTimeStampHostTimeValid : 0);
        struct { UInt32 count; AudioBuffer buffers[2]; } raw = {2, {{1, 0, nullptr}, {1, 0, nullptr}}};
        auto *data = reinterpret_cast<AudioBufferList *>(&raw);
        AudioUnitRenderActionFlags flags = 0;
        check(render(&flags, &time, count, 0, data, nullptr, pull) == noErr, "render succeeds with host-owned null buffers");
        for (unsigned ch = 0; ch < 2; ++ch) for (unsigned i = 0; i < count; ++i) {
            const float signal = float(0.7 * sin(2 * M_PI * 997 * double(position + i) / rate)) * (ch == 0 ? 1 : -0.6f);
            const float gain = float(std::clamp((double(position + i) - start) / duration, 0.0, 1.0));
            const float oldSignal = signal * (identical || destination == 1 ? 1 : -1);
            const float newSignal = signal * (identical || destination == 0 ? 1 : -1);
            const float expected = oldSignal * (1 - gain) + newSignal * gain;
            largestError = std::max(largestError, double(fabs(static_cast<float *>(data->mBuffers[ch].mData)[i] - expected)));
        }
        position += count;
    }
    check(largestError < 2e-6, "per-sample waveform matches expected envelope");
    check(unit.handoffComplete, "completion is published without UI polling");
    check(oldPullsAfterEnd == 0, "silent old input is no longer pulled");
    [unit selectInput:1 - destination];
    check(!unit.handoffComplete, "cancellation invalidates completion");
    [unit deallocateRenderResources];
}

static void engineCheck() {
    AVAudioEngine *engine = [AVAudioEngine new];
    AVAudioPlayerNode *a = [AVAudioPlayerNode new], *b = [AVAudioPlayerNode new];
    AVAudioUnitEffect *mixer = [OngakuHandoffMixer makeNode];
    [engine attachNode:a]; [engine attachNode:b]; [engine attachNode:mixer];
    AVAudioFormat *format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:96000 channels:2];
    [engine connect:a to:mixer fromBus:0 toBus:0 format:format];
    [engine connect:b to:mixer fromBus:0 toBus:1 format:format];
    [engine connect:mixer to:engine.mainMixerNode format:format];
    NSError *error = nil;
    check([engine enableManualRenderingMode:AVAudioEngineManualRenderingModeOffline format:format maximumFrameCount:512 error:&error], "engine offline setup");
    AVAudioPCMBuffer *inputA = [[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:16000];
    AVAudioPCMBuffer *inputB = [[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:16000];
    inputA.frameLength = inputB.frameLength = 16000;
    for (unsigned ch = 0; ch < 2; ++ch) for (unsigned i = 0; i < 16000; ++i) {
        inputA.floatChannelData[ch][i] = float(0.25 * sin(2 * M_PI * 997 * i / 96000));
        inputB.floatChannelData[ch][i] = float(0.75 * sin(2 * M_PI * 997 * (i + 1024) / 96000));
    }
    [a scheduleBuffer:inputA completionHandler:nil]; [b scheduleBuffer:inputB completionHandler:nil];
    check([engine startAndReturnError:&error], "dual-input engine starts");
    [a play]; [b playAtTime:[AVAudioTime timeWithSampleTime:1024 atRate:96000]];
    OngakuHandoffMixer *unit = (OngakuHandoffMixer *)mixer.AUAudioUnit;
    [unit scheduleInput:1 atHostTime:0 atSampleTime:1024 durationFrames:6144];
    AVAudioPCMBuffer *output = [[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:512];
    for (int block = 0; block < 24; ++block) {
        check([engine renderOffline:512 toBuffer:output error:&error] == AVAudioEngineManualRenderingStatusSuccess, "engine renders mixer");
        for (unsigned i = 0; i < 512; ++i) {
            double gain = std::clamp((double(block * 512 + i) - 1024) / 6144, 0.0, 1.0);
            double expected = (0.25 + 0.5 * gain) * sin(2 * M_PI * 997 * (block * 512 + i) / 96000);
            check(fabs(output.floatChannelData[0][i] - expected) < 2e-6, "scheduled player waveform follows envelope");
        }
    }
    check(unit.handoffComplete, "engine transition completes");
    [engine stop];
    puts("PASS: actual two-player AVAudioEngine graph, 96 kHz, sample-accurate fade without UI callbacks");
}

static void boundaryChecks() {
    AVAudioUnitEffect *node = [OngakuHandoffMixer makeNode];
    OngakuHandoffMixer *unit = (OngakuHandoffMixer *)node.AUAudioUnit;
    unit.maximumFramesToRender = 128;
    NSError *error = nil;
    check([unit allocateRenderResourcesAndReturnError:&error], "boundary resources");
    auto render = unit.internalRenderBlock;
    __block bool silence = false, fail = false;
    AURenderPullInputBlock pull = ^AUAudioUnitStatus(AudioUnitRenderActionFlags *flags, const AudioTimeStamp *,
                                                   AUAudioFrameCount count, NSInteger bus, AudioBufferList *data) {
        if (fail) return kAudioUnitErr_CannotDoInCurrentContext;
        if (silence) { *flags |= kAudioUnitRenderAction_OutputIsSilence; return noErr; }
        for (unsigned ch = 0; ch < 2; ++ch)
            std::fill_n(static_cast<float *>(data->mBuffers[ch].mData), count, bus == 0 ? 0.25f : 0.75f);
        return noErr;
    };
    float left[128], right[128];
    auto run = [&](double sample, unsigned count, bool valid = true) {
        struct { UInt32 count; AudioBuffer buffers[2]; } raw = {2, {{1, sizeof(left), left}, {1, sizeof(right), right}}};
        AudioTimeStamp time = {};
        time.mSampleTime = sample; time.mFlags = valid ? kAudioTimeStampSampleTimeValid : 0;
        AudioUnitRenderActionFlags flags = 0;
        return render(&flags, &time, count, 0, reinterpret_cast<AudioBufferList *>(&raw), nullptr, pull);
    };
    [unit selectInput:0];
    check(run(0, 32) == noErr && left[31] == 0.25f, "initial dry input");
    [unit scheduleInput:1 atHostTime:0 atSampleTime:64 durationFrames:64];
    check(run(32, 32) == noErr && left[31] == 0.25f, "future fade holds old input");
    check(run(64, 32) == noErr && fabs(left[31] - (0.25f + 0.5f * 31 / 64)) < 1e-7, "partial fade");
    [unit selectInput:1];
    check(run(96, 32) == noErr && left[0] == 0.75f && right[31] == 0.75f, "cancel settles selected input");
    [unit scheduleInput:0 atHostTime:0 atSampleTime:128 durationFrames:64];
    check(!unit.handoffComplete, "rearm invalidates old completion");
    check(run(128, 64) == noErr && fabs(left[63] - (0.75f - 0.5f * 63 / 64)) < 1e-7, "reverse fade");
    check(run(192, 32) == noErr && left[0] == 0.25f && unit.handoffComplete, "reverse completes");
    check(run(0, 32, false) == noErr && left[0] == 0.25f, "lost clock cannot resurrect old input after completion");
    silence = true;
    check(run(224, 32) == noErr && left[0] == 0 && right[31] == 0, "silence flag clears stale scratch samples");
    fail = true;
    check(run(256, 32) == kAudioUnitErr_CannotDoInCurrentContext, "upstream error propagated");
    check(run(256, 129) == kAudioUnitErr_TooManyFramesToProcess, "oversized buffer rejected before writing");
    [unit deallocateRenderResources];
    check(run(256, 32) == kAudioUnitErr_TooManyFramesToProcess, "unallocated rendering fails safely");
    puts("PASS: mid-fade cancellation, reverse/rearm, missing clock, silence, errors and buffer limits");
}

int main() { @autoreleasepool {
    for (double rate : {44100., 48000., 96000.})
        for (bool host : {false, true}) for (bool same : {false, true})
            for (unsigned input : {0u, 1u}) renderCheck(rate, host, same, input);
    puts("PASS: 24 AU render cases; variable blocks, both directions, correlated/opposite signals, clock modes, cancellation");
    engineCheck();
    boundaryChecks();
} }
