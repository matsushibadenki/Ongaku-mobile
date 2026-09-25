#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN
/// Private, in-process two-input mixer. Control methods must share one thread.
@interface OngakuHandoffMixer : AUAudioUnit
+ (AVAudioUnitEffect *)makeNode;
- (void)selectInput:(NSUInteger)input;
- (void)scheduleInput:(NSUInteger)input
          atHostTime:(uint64_t)hostTime
        atSampleTime:(double)sampleTime
      durationFrames:(uint64_t)frames;
@property(nonatomic, readonly) BOOL handoffComplete;
@end
NS_ASSUME_NONNULL_END
