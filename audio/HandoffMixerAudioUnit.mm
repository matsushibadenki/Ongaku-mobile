#import "HandoffMixerAudioUnit.h"
#include "HandoffMixerDSP.hpp"
#include <mach/mach_time.h>
#include <vector>
#include <memory>
#include <cstdlib>
#include <cstring>

namespace {
struct RenderStorage {
    ongaku::HandoffEnvelope envelope;
    std::vector<float> input[2], output;
    AudioBufferList *lists[2] = {nullptr, nullptr};
    uint32_t channels = 0, capacity = 0;
    double rate = 0, secondsPerTick = 0;
    ~RenderStorage() { clear(); }
    void clear() {
        for (auto &list : lists) { free(list); list = nullptr; }
        for (auto &buffer : input) { std::vector<float>().swap(buffer); }
        std::vector<float>().swap(output);
        capacity = 0;
    }
    bool allocate(uint32_t channelCount, uint32_t frameCount, double sampleRate) {
        clear();
        channels = channelCount; capacity = frameCount; rate = sampleRate;
        mach_timebase_info_data_t timebase;
        mach_timebase_info(&timebase);
        secondsPerTick = double(timebase.numer) / double(timebase.denom) * 1e-9;
        try {
            for (auto &buffer : input) buffer.resize(size_t(channels) * capacity);
            output.resize(size_t(channels) * capacity);
        } catch (...) { clear(); return false; }
        for (auto &list : lists) {
            list = static_cast<AudioBufferList *>(calloc(1, offsetof(AudioBufferList, mBuffers) + sizeof(AudioBuffer) * channels));
            if (!list) { clear(); return false; }
            list->mNumberBuffers = channels;
        }
        return true;
    }
    AUAudioUnitStatus render(AudioUnitRenderActionFlags *flags, const AudioTimeStamp *time,
                            AUAudioFrameCount count, AudioBufferList *data,
                            __unsafe_unretained AURenderPullInputBlock pull) noexcept {
        if (!pull) return kAudioUnitErr_NoConnection;
        if (count > capacity || capacity == 0) return kAudioUnitErr_TooManyFramesToProcess;
        if (data->mNumberBuffers != channels) return kAudioUnitErr_FormatNotSupported;
        if (count == 0) return noErr;
        const auto block = envelope.begin(time->mHostTime, time->mFlags & kAudioTimeStampHostTimeValid,
                                          time->mSampleTime, time->mFlags & kAudioTimeStampSampleTimeValid,
                                          rate, secondsPerTick);
        const size_t bytes = count * sizeof(float);
        for (unsigned bus = 0; bus < 2; ++bus) {
            if (!block.needsInput(bus, count)) continue;
            auto *list = lists[bus];
            for (uint32_t ch = 0; ch < channels; ++ch)
                list->mBuffers[ch] = {1, uint32_t(bytes), input[bus].data() + size_t(ch) * capacity};
            AudioUnitRenderActionFlags inputFlags = 0;
            const auto status = pull(&inputFlags, time, count, bus, list);
            if (status != noErr) return status;
            if (list->mNumberBuffers != channels) return kAudioUnitErr_FormatNotSupported;
            for (uint32_t ch = 0; ch < channels; ++ch) {
                auto *owned = input[bus].data() + size_t(ch) * capacity;
                const auto &buffer = list->mBuffers[ch];
                if (inputFlags & kAudioUnitRenderAction_OutputIsSilence) memset(owned, 0, bytes);
                else {
                    if (!buffer.mData || buffer.mDataByteSize < bytes) return kAudioUnitErr_InvalidPropertyValue;
                    if (buffer.mData != owned) memcpy(owned, buffer.mData, bytes);
                }
            }
        }
        const auto destination = block.destination;
        const auto origin = 1 - destination;
        const bool needsOld = block.needsInput(origin, count), needsNew = block.needsInput(destination, count);
        for (uint32_t ch = 0; ch < channels; ++ch) {
            auto &buffer = data->mBuffers[ch];
            if (!buffer.mData) buffer.mData = output.data() + size_t(ch) * capacity;
            else if (buffer.mDataByteSize < bytes) return kAudioUnitErr_InvalidPropertyValue;
            buffer.mNumberChannels = 1; buffer.mDataByteSize = uint32_t(bytes);
            auto *out = static_cast<float *>(buffer.mData);
            const auto *oldSamples = input[origin].data() + size_t(ch) * capacity;
            const auto *newSamples = input[destination].data() + size_t(ch) * capacity;
            if (!needsOld) memcpy(out, newSamples, bytes);
            else if (!needsNew) memcpy(out, oldSamples, bytes);
            else for (uint32_t frame = 0; frame < count; ++frame) {
                const float gain = block.newGain(frame);
                out[frame] = oldSamples[frame] * (1 - gain) + newSamples[frame] * gain;
            }
        }
        *flags &= ~kAudioUnitRenderAction_OutputIsSilence;
        envelope.finish(block, count);
        return noErr;
    }
};
}

@implementation OngakuHandoffMixer {
    AUAudioUnitBusArray *_inputs;
    AUAudioUnitBusArray *_outputs;
    std::unique_ptr<RenderStorage> _storage;
}
+ (AVAudioUnitEffect *)makeNode {
    static dispatch_once_t once;
    AudioComponentDescription description = {kAudioUnitType_Effect, 'ohmx', 'Ongk', 0, 0};
    dispatch_once(&once, ^{
        [AUAudioUnit registerSubclass:self asComponentDescription:description name:@"Ongaku:Handoff Mixer" version:1];
    });
    return [[AVAudioUnitEffect alloc] initWithAudioComponentDescription:description];
}
- (instancetype)initWithComponentDescription:(AudioComponentDescription)description
                                    options:(AudioComponentInstantiationOptions)options
                                      error:(NSError **)error {
    self = [super initWithComponentDescription:description options:options error:error];
    if (!self) return nil;
    _storage = std::make_unique<RenderStorage>();
    AVAudioFormat *format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:96000 channels:2];
    AUAudioUnitBus *a = [[AUAudioUnitBus alloc] initWithFormat:format error:error];
    AUAudioUnitBus *b = [[AUAudioUnitBus alloc] initWithFormat:format error:error];
    AUAudioUnitBus *out = [[AUAudioUnitBus alloc] initWithFormat:format error:error];
    if (!a || !b || !out) return nil;
    _inputs = [[AUAudioUnitBusArray alloc] initWithAudioUnit:self busType:AUAudioUnitBusTypeInput busses:@[a, b]];
    _outputs = [[AUAudioUnitBusArray alloc] initWithAudioUnit:self busType:AUAudioUnitBusTypeOutput busses:@[out]];
    self.maximumFramesToRender = 4096;
    return self;
}
- (AUAudioUnitBusArray *)inputBusses { return _inputs; }
- (AUAudioUnitBusArray *)outputBusses { return _outputs; }
- (BOOL)canProcessInPlace { return NO; }
- (BOOL)allocateRenderResourcesAndReturnError:(NSError **)error {
    AVAudioFormat *format = _outputs[0].format;
    if (format.commonFormat != AVAudioPCMFormatFloat32 || format.interleaved ||
        format.channelCount == 0 || format.channelCount > 32 || !std::isfinite(format.sampleRate) || format.sampleRate <= 0 ||
        self.maximumFramesToRender == 0 || self.maximumFramesToRender > 65536 ||
        ![format isEqual:_inputs[0].format] || ![format isEqual:_inputs[1].format]) {
        if (error) *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:kAudioUnitErr_FormatNotSupported userInfo:nil];
        return NO;
    }
    if (![super allocateRenderResourcesAndReturnError:error]) return NO;
    if (!_storage->allocate(format.channelCount, self.maximumFramesToRender, format.sampleRate)) {
        [super deallocateRenderResources];
        if (error) *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:kAudioUnitErr_FailedInitialization userInfo:nil];
        return NO;
    }
    return YES;
}
- (void)deallocateRenderResources {
    [super deallocateRenderResources];
    _storage->clear();
}
- (AUInternalRenderBlock)internalRenderBlock {
    // Capture only a stable C++ pointer: no ObjC/Swift calls, allocation, logging,
    // reference-count operations or blocking locks in our render implementation.
    RenderStorage *storage = _storage.get();
    return ^AUAudioUnitStatus(AudioUnitRenderActionFlags *flags, const AudioTimeStamp *time,
                             AUAudioFrameCount count, NSInteger bus, AudioBufferList *data,
                             const AURenderEvent *events, __unsafe_unretained AURenderPullInputBlock pull) {
        if (bus != 0) return kAudioUnitErr_InvalidElement;
        return storage->render(flags, time, count, data, pull);
    };
}
- (void)selectInput:(NSUInteger)input { _storage->envelope.select(input); }
- (void)scheduleInput:(NSUInteger)input atHostTime:(uint64_t)hostTime
        atSampleTime:(double)sampleTime durationFrames:(uint64_t)frames {
    _storage->envelope.schedule(input, hostTime, sampleTime, frames);
}
- (BOOL)handoffComplete { return _storage->envelope.isComplete(); }
@end
