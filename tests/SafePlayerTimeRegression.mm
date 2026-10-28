#import "../audio/TruePeakAudioUnit.h"
#import <Foundation/Foundation.h>
#include <cstdio>
#include <cstdlib>
#include <cmath>

static void check(bool condition, const char *message) {
    if (!condition) { fprintf(stderr, "FAIL: %s\n", message); exit(1); }
}

@interface ThrowingPlayerNode : AVAudioPlayerNode
@property(nonatomic) NSUInteger calls;
@end
@implementation ThrowingPlayerNode
- (AVAudioTime *)playerTimeForNodeTime:(AVAudioTime *)nodeTime {
    self.calls += 1;
    @throw [NSException exceptionWithName:@"InjectedClockException" reason:@"reconfigured" userInfo:nil];
}
@end

int main() { @autoreleasepool {
    ThrowingPlayerNode *fake = [ThrowingPlayerNode new];
    AVAudioTime *valid = [AVAudioTime timeWithSampleTime:0 atRate:48000];
    bool sawException = false;
    @try { (void)[fake playerTimeForNodeTime:valid]; }
    @catch (NSException *exception) { sawException = [exception.name isEqualToString:@"InjectedClockException"]; }
    check(sawException, "negative control must raise the same kind of Objective-C exception");
    check(OngakuSafePlayerTime(fake, valid) == nil && fake.calls == 2, "exception becomes unavailable clock");
    AudioTimeStamp empty = {};
    AVAudioTime *invalid = [AVAudioTime timeWithAudioTimeStamp:&empty sampleRate:48000];
    check(!invalid.isSampleTimeValid && !invalid.isHostTimeValid, "empty timestamp fixture");
    check(OngakuSafePlayerTime(fake, invalid) == nil && fake.calls == 2, "invalid timestamp never invokes conversion");

    AVAudioEngine *engine = [AVAudioEngine new]; AVAudioPlayerNode *player = [AVAudioPlayerNode new];
    AVAudioFormat *format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:48000 channels:2];
    [engine attachNode:player]; [engine connect:player to:engine.mainMixerNode format:format];
    NSError *error = nil;
    check([engine enableManualRenderingMode:AVAudioEngineManualRenderingModeOffline format:format maximumFrameCount:512 error:&error], "manual mode");
    AVAudioPCMBuffer *input = [[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:4096]; input.frameLength=4096;
    for (unsigned ch=0; ch<2; ++ch) for (unsigned i=0; i<4096; ++i) input.floatChannelData[ch][i] = 0.1f * sin(i*0.1f);
    [player scheduleBuffer:input atTime:nil options:0 completionHandler:nil];
    check([engine startAndReturnError:&error], "start engine"); [player play];
    AVAudioPCMBuffer *output = [[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:512];
    for (unsigned i=0; i<4; ++i) check([engine renderOffline:512 toBuffer:output error:&error] == AVAudioEngineManualRenderingStatusSuccess, "render");
    AVAudioTime *stamp=player.lastRenderTime;
    check(stamp != nil, "render clock available");
    AVAudioTime *time=OngakuSafePlayerTime(player,stamp);
    check(time != nil && time.isSampleTimeValid && time.sampleTime > 0, "live clock advances");
    [player stop]; [engine stop];
    (void)OngakuSafePlayerTime(player,stamp); // A stale stamp may return nil or a value; neither may throw.
    puts("PASS: injected Objective-C exception contained, invalid input skipped, live clock advances, stale clock does not crash");
} }
