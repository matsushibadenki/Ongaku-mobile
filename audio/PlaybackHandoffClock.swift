import Foundation

/// Pure timeline math shared by the engine and its offline regression tests.
/// No wall-clock dates: the caller supplies elapsed time from one render stamp.
nonisolated enum PlaybackHandoffClock {
    static let fadeDuration: TimeInterval = 0.064

    /// Invalid render stamps must not change either source gain.
    static func fadeProgress(renderedFrames: Int64, sampleRate: Double) -> Float? {
        guard renderedFrames >= 0, sampleRate.isFinite, sampleRate > 0 else { return nil }
        return Float(min(1, Double(renderedFrames) / sampleRate / fadeDuration))
    }

    struct Plan {
        let startFrame: Int64
        let startSeconds: TimeInterval
        let delayFromRenderTime: TimeInterval
    }

    static func plan(
        sourceOffset: TimeInterval,
        renderedFrames: Int64,
        sourceSampleRate: Double,
        leadFromRenderTime: TimeInterval,
        targetSampleRate: Double,
        targetFrameCount: Int64
    ) -> Plan? {
        guard sourceOffset.isFinite, sourceOffset >= 0,
              renderedFrames >= 0,
              sourceSampleRate.isFinite, sourceSampleRate > 0,
              targetSampleRate.isFinite, targetSampleRate > 0,
              leadFromRenderTime.isFinite, leadFromRenderTime > 0,
              targetFrameCount > 0 else { return nil }
        let renderedPosition = sourceOffset + Double(renderedFrames) / sourceSampleRate
        // Align the host-time start to the chosen PCM frame, not vice versa.
        // Round up so quantization never consumes the requested scheduling lead.
        let frame = ceil((renderedPosition + leadFromRenderTime) * targetSampleRate)
        guard frame.isFinite, frame >= 0, frame < Double(Int64.max),
              frame + ceil(fadeDuration * targetSampleRate) < Double(targetFrameCount)
        else { return nil }
        let startSeconds = frame / targetSampleRate
        return Plan(startFrame: Int64(frame), startSeconds: startSeconds,
                    delayFromRenderTime: startSeconds - renderedPosition)
    }
}
