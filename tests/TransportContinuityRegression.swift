import Foundation
import AVFoundation

@main struct TransportContinuityRegression {
    static func require(_ value: Bool, _ message: String) throws {
        if !value { throw NSError(domain: message, code: 1) }
    }
    static func ready() throws -> ShippingTransportHost {
        DispatchQueue.main.reset()
        let host = ShippingTransportHost()
        try host.play()
        DispatchQueue.main.advance(to: 0.1)
        try require(host.isPlaying && host.engine.mainMixerNode.outputVolume == 1, "default play remained muted")
        return host
    }
    static func main() {
        do { try run() }
        catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
    }
    static func run() throws {
        if CommandLine.arguments.contains("--early-teardown-fixture") {
            let host = try ready(); host.stop()
            try require(host.resourcesCleared == 0 && host.activePlayerNode.isPlaying,
                        "shutdown released source before fade and drain")
            return
        }
        let stalled = ShippingTransportHost()
        stalled.activePlayerNode.lastRenderTime = nil
        try stalled.play()
        DispatchQueue.main.advance(to: 0.1)
        try require(stalled.engine.mainMixerNode.outputVolume == 0, "fade started before render")
        stalled.activePlayerNode.lastRenderTime = RenderTime()
        DispatchQueue.main.advance(to: 0.2)
        try require(stalled.engine.mainMixerNode.outputVolume == 1, "render did not release fade")
        print("PASS: startup waits for render before fading")

        let paused = try ready()
        paused.livePosition = 3
        paused.pause()
        try require(!paused.isPlaying && paused.engine.isRunning && paused.currentTime() == 3, "pause intent not immediate")
        DispatchQueue.main.advance(to: 0.112)
        try require(paused.activePlayerNode.isPlaying && paused.handoffCancellations == 0, "handoff stopped before fade")
        DispatchQueue.main.advance(to: 0.125)
        try require(paused.engine.mainMixerNode.outputVolume == 0 && paused.engine.isRunning, "pause skipped silent drain")
        DispatchQueue.main.advance(to: 0.15)
        try require(!paused.engine.isRunning && paused.playbackOffset == 3, "pause did not commit at zero")
        try paused.play(); DispatchQueue.main.advance(to: 0.2)
        try require(paused.isPlaying && paused.schedules == 2 && paused.engine.mainMixerNode.outputVolume == 1, "paused resume failed")
        print("PASS: pause intent, silent drain, position and restart")

        let rapid = try ready()
        rapid.pause(); DispatchQueue.main.advance(to: 0.105)
        let before = rapid.engine.mainMixerNode.outputVolume
        try rapid.play()
        try require(rapid.engine.mainMixerNode.outputVolume == before, "rapid resume jumped gain")
        DispatchQueue.main.advance(to: 0.3)
        try require(rapid.isPlaying && rapid.schedules == 1 && rapid.engine.mainMixerNode.outputVolume == 1, "stale pause killed resume")
        print("PASS: rapid resume cancels old gains and pause without rescheduling")

        let stopped = try ready()
        stopped.pause(); DispatchQueue.main.advance(to: 0.105)
        stopped.stop()
        do { try stopped.play(); throw NSError(domain: "play during teardown accepted", code: 1) }
        catch is CancellationError { }
        DispatchQueue.main.advance(to: 0.15)
        try stopped.play(); DispatchQueue.main.advance(to: 0.3)
        try require(stopped.isPlaying && stopped.engine.mainMixerNode.outputVolume == 1, "old pause muted new track")
        print("PASS: stop invalidates transport callbacks before new playback")

        let retiring = try ready()
        var cleanup = 0
        retiring.stop(afterDrain: { cleanup += 1 })
        try require(!retiring.isPlaying && retiring.currentTime() == 0, "stop intent not immediate")
        try require(retiring.activePlayerNode.isPlaying && retiring.resourcesCleared == 0, "stop released active source before fade")
        DispatchQueue.main.advance(to: 0.112)
        retiring.pause() // Must not replace/cancel the pending destructive drain.
        do { try retiring.seek(to: 5); throw NSError(domain: "seek during teardown accepted", code: 1) }
        catch is CancellationError { }
        let originalToken = retiring.transportToken
        retiring.stop(afterDrain: { cleanup += 10 })
        try require(retiring.transportToken == originalToken, "repeated stop restarted its fade")
        DispatchQueue.main.advance(to: 0.125)
        try require(retiring.engine.mainMixerNode.outputVolume == 0 && retiring.resourcesCleared == 0 && cleanup == 0, "stop skipped silent drain")
        retiring.handlePlaybackEnd(generation: retiring.playbackGeneration)
        DispatchQueue.main.advance(to: 0.137)
        try require(retiring.resourcesCleared == 1 && !retiring.engine.isRunning && cleanup == 10, "stop cleanup/latest completion failed")
        print("PASS: stop retains sources through fade/drain; repeated stop coalesces and only latest session cleanup runs")

        let loading = try ready()
        var staleRelease = 0
        let obsoleteGeneration = loading.stop(afterDrain: { staleRelease += 1 })
        DispatchQueue.main.advance(to: 0.105)
        let nextGeneration = loading.stop() // New load owns the existing drain.
        try require(nextGeneration != obsoleteGeneration, "new load failed to invalidate old preparation")
        DispatchQueue.main.advance(to: 0.2)
        try require(staleRelease == 0 && loading.resourcesCleared == 1, "old session release survived superseding load")
        try loading.play(); DispatchQueue.main.advance(to: 0.3)
        try require(loading.isPlaying && loading.engine.mainMixerNode.outputVolume == 1, "new source was cleared by old stop")
        print("PASS: a superseding load cancels old preparation/session release and survives the old stop callbacks")

        DispatchQueue.main.reset()
        let idle = ShippingTransportHost()
        var idleCleanup = 0
        idle.stop(afterDrain: { idleCleanup += 1 })
        try require(idle.resourcesCleared == 1 && idleCleanup == 1 && DispatchQueue.main.events.isEmpty, "idle stop scheduled an unnecessary fade")
        print("PASS: an already-stopped engine releases resources synchronously")

        let seek = try ready()
        try seek.seek(to: 7); DispatchQueue.main.advance(to: 0.105)
        seek.pause(); DispatchQueue.main.advance(to: 0.2)
        try require(!seek.isPlaying && seek.schedules == 1, "cancelled seek restarted playback")
        try seek.seek(to: 4)
        try require(!seek.isPlaying && !seek.engine.isRunning && seek.playbackOffset == 4, "paused seek became audible")
        try seek.play(); DispatchQueue.main.advance(to: 0.3)
        try require(seek.isPlaying && seek.engine.mainMixerNode.outputVolume == 1, "seek resume remained muted")
        print("PASS: seek cancellation and paused seek")

        let latest = try ready()
        try latest.seek(to: 2); DispatchQueue.main.advance(to: 0.105)
        try latest.seek(to: 6); try latest.play()
        DispatchQueue.main.advance(to: 0.13)
        try require(latest.schedules == 1, "seek replaced source before silent drain")
        DispatchQueue.main.advance(to: 0.3)
        try require(latest.schedules == 2 && latest.playbackOffset == 6 && latest.isPlaying, "obsolete seek won")
        print("PASS: latest seek wins, including immediate seek/play callers")

        DispatchQueue.main.reset()
        let timeout = ShippingTransportHost()
        timeout.activePlayerNode.lastRenderTime = nil
        try timeout.play(); DispatchQueue.main.advance(to: 1.2)
        try require(!timeout.isPlaying && !timeout.engine.isRunning, "render timeout stayed silently playing")
        print("PASS: missing render ends in paused state")
        let eof = try ready()
        var ended = 0
        eof.onPlaybackEnded = { ended += 1 }
        eof.pause()
        eof.handlePlaybackEnd(generation: eof.playbackGeneration)
        try require(ended == 0, "EOF overrode pause")
        try eof.play(); DispatchQueue.main.advance(to: 0.2)
        try require(eof.schedules == 2 && eof.isPlaying, "resume reused a completed schedule")
        try eof.seek(to: 5)
        eof.handlePlaybackEnd(generation: eof.playbackGeneration)
        try require(ended == 0, "EOF overrode seek")
        DispatchQueue.main.advance(to: 0.3)
        eof.handlePlaybackEnd(generation: eof.playbackGeneration)
        try require(ended == 1, "new schedule lost natural EOF")
        print("PASS: EOF cannot override pause/seek; resume replaces an already-ended schedule")
        try waveforms()
    }

    static func waveforms() throws {
        // Actual stock mixer PCM, with deterministic control deadlines. This
        // proves bounded ideal scheduling, not physical/UI-load audibility.
        let negative = CommandLine.arguments.contains("--abrupt-fixture")
        var cases = 0
        for rate in [44100.0, 48000.0, 96000.0] {
            for direction in [false, true] {
                DispatchQueue.main.reset()
                let host = ShippingTransportWaveform()
                let player = AVAudioPlayerNode()
                let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
                host.engine.attach(player)
                host.engine.connect(player, to: host.engine.mainMixerNode, format: format)
                try host.engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 32)
                let source = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate))!
                source.frameLength = source.frameCapacity
                // DC exposes envelope discontinuities without carrier masking.
                for channel in 0..<2 { for frame in 0..<Int(source.frameLength) {
                    source.floatChannelData![channel][frame] = channel == 0 ? 0.4 : -0.2
                } }
                host.engine.mainMixerNode.outputVolume = negative ? 1 : (direction ? 0 : 1)
                player.scheduleBuffer(source); try host.engine.start()
                if !negative || !direction { player.play() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                    if negative {
                        if direction { player.play() } else { player.stop() }
                    }
                    else {
                        host.rampTransportVolume(to: direction ? 1 : 0, duration: 0.024, token: 0) {
                            if !direction {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.012) { player.stop() }
                            }
                        }
                    }
                }
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32)!
                var samples = [Float]()
                var rightSamples = [Float]()
                while samples.count < Int(rate * 0.08) {
                    DispatchQueue.main.advance(to: Double(host.engine.manualRenderingSampleTime) / rate)
                    try require(try host.engine.renderOffline(32, to: buffer) == .success, "render failed")
                    samples.append(contentsOf: UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
                    rightSamples.append(contentsOf: UnsafeBufferPointer(start: buffer.floatChannelData![1], count: Int(buffer.frameLength)))
                }
                try require(zip(samples, rightSamples).allSatisfy { $0.0.isFinite && $0.1.isFinite && abs($0.1 + $0.0 * 0.5) < 0.000001 }, "transport channels diverged")
                let start = Int(rate * 0.018), end = Int(rate * 0.065)
                let largest = (start..<end).map { abs(samples[$0] - samples[$0 - 1]) }.max()!
                try require(samples.allSatisfy(\.isFinite) && largest * Float(rate) < 25, "transport PCM contains abrupt boundary")
                if direction {
                    try require(samples.prefix(Int(rate * 0.018)).allSatisfy { abs($0) < 0.00001 }, "startup leaked before fade")
                } else {
                    let silentAfterDrain = samples[Int(rate * 0.056)...].allSatisfy { abs($0) < 0.00001 }
                    try require(silentAfterDrain, "mixer still audible when pause drain ends")
                }
                let tail = samples.suffix(256).reduce(0, +) / 256
                try require(abs(tail - (direction ? 0.4 : 0)) < 0.0001, "transport target not reached")
                print("TRANSPORT_PCM rate=\(rate) fadeIn=\(direction) maxStep=\(largest)")
                player.stop(); host.engine.stop(); cases += 1
            }
        }
        print("PASS: \(cases) stock-mixer PCM fade cases")
    }
}
