import SwiftUI
import AVFoundation

@main struct DestructiveStopAuditApp: App {
    var body: some Scene { WindowGroup { Text("Shutdown audit").task { await run() } } }
    @MainActor private func run() async {
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let report = root.appendingPathComponent("native-first-result.txt")
        var lines: [String] = []
        func log(_ text: String) { lines.append(text); try? lines.joined(separator: "\n").write(to: report, atomically: true, encoding: .utf8) }
        let engine = HiResPlaybackEngine()
        func field<T>(_ name: String, as type: T.Type) -> T {
            Mirror(reflecting: engine).children.first { $0.label == name }!.value as! T
        }
        let graph = field("engine", as: AVAudioEngine.self)
        func outputGain() -> Float {
#if ONGAKU_ENABLE_AUDIO_THREAD_GAIN
            field("transportAudioGain", as: AudioThreadGainStage.self).gain
#else
            graph.mainMixerNode.outputVolume
#endif
        }

        do {
            let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
            let source = root.appendingPathComponent("stop-source.caf")
            let next = root.appendingPathComponent("stop-next.caf")
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100 * 6)!
            buffer.frameLength = buffer.frameCapacity
            for channel in 0..<2 { for frame in 0..<Int(buffer.frameLength) {
                buffer.floatChannelData![channel][frame] = Float(sin(Double(frame) * 0.02)) * 0.015
            } }
            for url in [source, next] {
                let file = try AVAudioFile(forWriting: url, settings: format.settings)
                try file.write(from: buffer)
            }
            let effects = [RealtimeAudioEffectSetting(kind: .equalizer, isEnabled: true)]
            let reopened = try await StreamingAudioFilePreparation.open(url: source)
            let logicalSource = URL(string: "ipod-library://item/stop.caf?id=73")!
            // Destructive shutdown uses the same final envelope as pause, but
            // retains the file/PCM owners until the silent drain is complete.
            try await engine.load(url: source, effectSettings: effects, strategy: .immediateStreaming)
            try engine.play(); try await engine.waitForSystemHandoffRender()
            var retiredSession = 0
            let firstStop = engine.stop(afterDrain: { retiredSession += 1 })
            precondition(!engine.hasTrack && !engine.isPlaying && engine.currentTime() == 0)
            precondition(graph.isRunning && engine.currentAudioURL == source)
            do { try engine.play(); preconditionFailure("play crossed destructive drain") }
            catch is CancellationError { }
            let latestStop = engine.stop(afterDrain: {
                precondition(!graph.isRunning && engine.currentAudioURL == nil)
                retiredSession += 10
            })
            do { try await engine.waitForStop(generation: firstStop); preconditionFailure("obsolete wait accepted") }
            catch is CancellationError { }
            try await engine.waitForStop(generation: latestStop)
            precondition(retiredSession == 10 && outputGain() == 0)
            log("PASS: stop hides track immediately, retains file through drain, and invokes only the latest session release after teardown")

            try await engine.load(url: source, effectSettings: effects, strategy: .immediateStreaming)
            try engine.play(); try await engine.waitForSystemHandoffRender()
            var obsoleteStarted = false
            let obsoleteLoad = Task { @MainActor in
                obsoleteStarted = true
                try await engine.load(url: next, effectSettings: effects, strategy: .immediateStreaming)
            }
            while !obsoleteStarted { await Task.yield() }
            try await engine.loadOpenedFile(url: logicalSource, opened: reopened,
                effectSettings: effects, headphoneSpatialSettings: .default)
            do { try await obsoleteLoad.value; preconditionFailure("obsolete load installed its track") }
            catch is CancellationError { }
            try engine.play(); try await engine.waitForSystemHandoffRender()
            try await Task.sleep(for: .milliseconds(100))
            precondition(engine.currentAudioURL == logicalSource && engine.isPlaying && outputGain() == 1)
            log("PASS: overlapping load/loadOpenedFile requests wait for one drain; newest source survives old stop and load callbacks")

            let cancelledBeforeEntry = Task { @MainActor in
                try await engine.load(url: next, effectSettings: effects, strategy: .immediateStreaming)
            }
            cancelledBeforeEntry.cancel()
            do { try await cancelledBeforeEntry.value; preconditionFailure("pre-cancelled load entered teardown") }
            catch is CancellationError { }
            precondition(engine.isPlaying && engine.currentAudioURL == logicalSource && outputGain() == 1)
            log("PASS: a load cancelled before entry cannot stop the currently audible source")

            var cancelledStarted = false
            let cancelledLoad = Task { @MainActor in
                cancelledStarted = true
                try await engine.load(url: next, effectSettings: effects, strategy: .immediateStreaming)
            }
            while !cancelledStarted { await Task.yield() }
            cancelledLoad.cancel()
            do { try await cancelledLoad.value; preconditionFailure("cancelled load installed source") }
            catch is CancellationError { }
            try await engine.waitForStop()
            precondition(!engine.hasTrack && !graph.isRunning && engine.currentAudioURL == nil)
            log("PASS: cancellation while waiting for drain does not strand resources or install a cancelled source")

            try await engine.load(url: source, effectSettings: effects, strategy: .immediateStreaming)
            try engine.play(); try await engine.waitForSystemHandoffRender()
            var reloadStarted = false
            let reload = Task { @MainActor in
                reloadStarted = true
                try await engine.reloadCurrentTrack(url: source, effectSettings: effects,
                    headphoneSpatialSettings: .default, upsamplingMode: .avAudioConverter,
                    resumeTime: 2, shouldResume: true)
            }
            while !reloadStarted { await Task.yield() }
            engine.pause()
            try await reload.value
            precondition(engine.hasTrack && !engine.isPlaying && abs(engine.currentTime() - 2) < 0.05)
            log("PASS: quality/recovery reload waits for teardown and respects a newer pause during its drain")

            try await engine.loadOpenedFile(url: logicalSource, opened: reopened,
                effectSettings: effects, headphoneSpatialSettings: .default)
            try engine.play(); try await engine.waitForSystemHandoffRender()
            try await engine.seamlessUpgrade(url: logicalSource, preparationURL: source,
                effectSettings: effects, headphoneSpatialSettings: .default,
                upsamplingMode: .avAudioConverter, shouldResume: true)
            let pendingOverlap = Mirror(reflecting: engine).children.first { $0.label == "pendingHandoff" }!.value
            precondition(!Mirror(reflecting: pendingOverlap).children.isEmpty)
            let overlapStop = engine.stop()
            precondition(graph.isRunning && engine.currentAudioURL != nil)
            try await engine.waitForStop(generation: overlapStop)
            precondition(!graph.isRunning && !field("playerNode", as: AVAudioPlayerNode.self).isPlaying
                && !field("upgradePlayerNode", as: AVAudioPlayerNode.self).isPlaying)
            precondition(engine.currentAudioURL == nil && outputGain() == 0)
            log("PASS: destructive stop retains both quality-handoff schedules until silence and then clears both nodes")
            log("COMPLETE")
        } catch { engine.stop(); log("FAIL: \(error)") }
    }
}
