import AVFoundation
import Foundation

@main
struct RenderHealthRegression {
    static func main() throws {
        // The reported 887.5 ms meter-delivery gap while actual render cycles
        // continue at 10 ms must not be called a render interruption.
        let tapOnly = AudioRenderHealthMonitor()
        tapOnly.beginMonitoring(nowNanoseconds: 1_000_000_000)
        tapOnly.recordTapDelivery(frameCount: 1_024, sampleRate: 48_000, nowNanoseconds: 1_000_000_000)
        for tick in 0...90 {
            tapOnly.recordRender(frameCount: 480, sampleRate: 48_000,
                                 nowNanoseconds: 1_000_000_000 + UInt64(tick) * 10_000_000)
        }
        tapOnly.recordTapDelivery(frameCount: 1_024, sampleRate: 48_000, nowNanoseconds: 1_887_500_000)
        let tapResult = tapOnly.poll(expectedToRender: true, nowNanoseconds: 1_900_000_000)
        precondition(tapResult.snapshot == .healthy && tapResult.renderCallbackCount == 91)
        precondition(tapResult.detectedGapMilliseconds == nil && tapResult.recoveredAfterMilliseconds == nil)
        precondition(tapResult.tapDeliveryGapMilliseconds == 887.5)
        precondition(tapOnly.poll(expectedToRender: true, nowNanoseconds: 1_900_000_000).tapDeliveryGapMilliseconds == nil)
        print("PASS: 887.5 ms tap-delivery delay leaves continuous render cycles healthy")

        let stalled = AudioRenderHealthMonitor()
        stalled.beginMonitoring(nowNanoseconds: 1_000_000_000)
        stalled.recordRender(frameCount: 480, sampleRate: 48_000, nowNanoseconds: 1_000_000_000)
        let firstPoll = stalled.poll(expectedToRender: true, nowNanoseconds: 1_400_000_000)
        precondition(firstPoll.snapshot.dropoutCount == 1 && firstPoll.snapshot.isStalled)
        precondition(firstPoll.detectedGapMilliseconds == 400)
        precondition(stalled.poll(expectedToRender: true, nowNanoseconds: 1_500_000_000).detectedGapMilliseconds == nil)
        stalled.recordRender(frameCount: 480, sampleRate: 48_000, nowNanoseconds: 1_887_500_000)
        let recovery = stalled.poll(expectedToRender: true, nowNanoseconds: 1_887_500_000)
        precondition(recovery.snapshot.dropoutCount == 1 && !recovery.snapshot.isStalled)
        precondition(recovery.recoveredAfterMilliseconds == 887.5)
        precondition(recovery.snapshot.maxRenderGapMilliseconds == 887.5)
        print("PASS: actual render stall is counted once and recovery retains its duration")

        let delayedFirst = AudioRenderHealthMonitor()
        delayedFirst.beginMonitoring(nowNanoseconds: 1_000_000_000)
        precondition(delayedFirst.poll(expectedToRender: true, nowNanoseconds: 1_999_000_000).snapshot == .healthy)
        precondition(delayedFirst.poll(expectedToRender: true, nowNanoseconds: 2_100_000_000).snapshot.isStalled)
        delayedFirst.recordRender(frameCount: 512, sampleRate: 48_000, nowNanoseconds: 2_200_000_000)
        let initialRecovery = delayedFirst.poll(expectedToRender: true, nowNanoseconds: 2_200_000_000)
        precondition(!initialRecovery.snapshot.isStalled && initialRecovery.recoveredAfterMilliseconds == 1_200)
        print("PASS: startup grace and recovery from a missing first render callback")

        delayedFirst.endMonitoring()
        delayedFirst.recordTapDelivery(frameCount: 512, sampleRate: 48_000, nowNanoseconds: 5_000_000_000)
        delayedFirst.recordRender(frameCount: 512, sampleRate: 48_000, nowNanoseconds: 5_000_000_000)
        precondition(!delayedFirst.poll(expectedToRender: true, nowNanoseconds: 5_000_000_000).snapshot.isStalled)
        delayedFirst.beginMonitoring(nowNanoseconds: 10_000_000_000)
        delayedFirst.recordRender(frameCount: 512, sampleRate: 48_000, nowNanoseconds: 10_010_000_000)
        let restarted = delayedFirst.poll(expectedToRender: true, nowNanoseconds: 10_010_000_000)
        precondition(restarted.snapshot.dropoutCount == 1 && !restarted.snapshot.isStalled)
        precondition(restarted.detectedGapMilliseconds == nil && restarted.tapDeliveryGapMilliseconds == nil)
        print("PASS: paused time and new schedules cannot produce stale gap events")

        let monitoredPCM = try realRenderObserver(enabled: true)
        let baselinePCM = try realRenderObserver(enabled: false)
        precondition(monitoredPCM == baselinePCM)
        print("PASS: observer-enabled and observer-free stereo PCM are sample-for-sample identical")
    }

    static func realRenderObserver(enabled: Bool) throws -> [Float] {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
        let monitor = AudioRenderHealthMonitor()
        var heartbeat: AudioRenderHeartbeat? = enabled ? AudioRenderHeartbeat(
            unit: engine.mainMixerNode.auAudioUnit, sampleRate: 48_000, monitor: monitor
        ) : nil
        weak let weakHeartbeat = heartbeat
        let source = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)!
        source.frameLength = 48_000
        for channel in 0..<2 {
            for frame in 0..<48_000 {
                source.floatChannelData![channel][frame] = Float(0.2 * sin(Double(frame) * 2 * .pi *
                    (channel == 0 ? 997 : 2_303) / 48_000))
            }
        }
        player.scheduleBuffer(source)
        try engine.start()
        monitor.beginMonitoring()
        player.play()
        let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
        var pcm: [Float] = []
        for _ in 0..<16 {
            let status = try engine.renderOffline(512, to: output)
            precondition(status == .success)
            for channel in 0..<2 {
                pcm.append(contentsOf: UnsafeBufferPointer(start: output.floatChannelData![channel], count: 512))
            }
        }
        let beforeRemoval = monitor.poll(expectedToRender: true)
        precondition(beforeRemoval.renderCallbackCount == (enabled ? 16 : 0),
                     "Expected one pre-render callback per slice, got \(beforeRemoval.renderCallbackCount)")
        precondition(beforeRemoval.snapshot == .healthy)
        heartbeat = nil
        precondition(weakHeartbeat == nil)
        for _ in 0..<4 { let status = try engine.renderOffline(512, to: output); precondition(status == .success) }
        precondition(monitor.poll(expectedToRender: false).renderCallbackCount == (enabled ? 16 : 0))
        engine.stop()
        if enabled { print("PASS: shipping Audio Unit observer counts pre-render cycles once and removes its token") }
        precondition(pcm.contains { abs($0) > 0.1 })
        return pcm
    }
}
