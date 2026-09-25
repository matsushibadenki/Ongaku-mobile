import AVFoundation
import Foundation

@main
struct PlaybackHandoffRegression {
    static func main() {
        // Include seeks with fractional seconds and long tracks. The source
        // player timeline need not have the same rate as the prepared buffer.
        for sourceRate in [44_100.0, 48_000, 96_000, 192_000] {
            for targetRate in [44_100.0, 48_000, 96_000] {
                for offset in [0.0, 17.123456, 7_200.98765] {
                    let frames: Int64 = 123_457
                    let lead = 0.0834567
                    let plan = PlaybackHandoffClock.plan(
                        sourceOffset: offset, renderedFrames: frames, sourceSampleRate: sourceRate,
                        leadFromRenderTime: lead, targetSampleRate: targetRate,
                        targetFrameCount: Int64(targetRate * 10_000))!
                    let oldPosition = offset + Double(frames) / sourceRate
                    let oldAtStart = oldPosition + plan.delayFromRenderTime
                    precondition(abs(oldAtStart - Double(plan.startFrame) / targetRate) < 1e-9)
                    precondition(plan.delayFromRenderTime >= lead - 1e-9)
                    precondition(plan.delayFromRenderTime - lead < 1 / targetRate + 1e-9)
                    let hostDelta = AVAudioTime.hostTime(forSeconds: plan.delayFromRenderTime)
                    let representedDelta = AVAudioTime.seconds(forHostTime: hostDelta)
                    precondition(abs(representedDelta - plan.delayFromRenderTime) * targetRate < 0.01)
                }
            }
        }
        print("PASS: 36 rate/seek combinations align PCM and host-clock positions without drift")

        func plan(_ frames: Int64 = 0, rate: Double = 96_000,
                  lead: Double = 0.08, offset: Double = 0,
                  length: Int64 = 960_000) -> PlaybackHandoffClock.Plan? {
            PlaybackHandoffClock.plan(sourceOffset: offset, renderedFrames: frames,
                sourceSampleRate: rate, leadFromRenderTime: lead,
                targetSampleRate: 96_000, targetFrameCount: length)
        }
        precondition(plan(950_000) == nil)
        precondition(plan(length: 0) == nil)
        precondition(plan(-1) == nil)
        precondition(plan(rate: 0) == nil)
        precondition(plan(rate: .nan) == nil)
        precondition(plan(lead: .infinity) == nil)
        precondition(plan(lead: -1) == nil)
        precondition(plan(offset: .nan) == nil)
        precondition(plan(offset: Double.greatestFiniteMagnitude) == nil)
        print("PASS: invalid clocks and insufficient tails defer without a bogus frame")

        // Fade-progress/unity-gain checks now exercise the actual audio unit in
        // HandoffMixerRenderTests.mm, rather than an unused Swift approximation.
    }
}
