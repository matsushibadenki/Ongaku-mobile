import SwiftUI
import AVFoundation

// Standalone simulator host: copy over audioApp.swift in an isolated project.
@main
struct NativeFirstPlaybackAuditApp: App {
    var body: some Scene { WindowGroup { Text("Playback audit").task { await run() } } }

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
        let gainEQ = field("inputGainEQ", as: AVAudioUnitEQ.self)
        let automaticEQ = field("automaticDSPEQ", as: AVAudioUnitEQ.self)
        do {
            await HiResPlaybackEngine.clearPreparedAudioDiskCache()
            let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
            let source = root.appendingPathComponent("source.caf")
            let next = root.appendingPathComponent("next.caf")
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100 * 20)!
            buffer.frameLength = buffer.frameCapacity
            for channel in 0..<2 { for frame in 0..<Int(buffer.frameLength) {
                buffer.floatChannelData![channel][frame] = Float(sin(Double(frame) * 0.02)) * 0.015
            } }
            for url in [source, next] {
                let file = try AVAudioFile(forWriting: url, settings: format.settings)
                try file.write(from: buffer)
            }
            let missing = root.appendingPathComponent("missing-diagnostic-source.caf")
            do {
                try await engine.load(url: missing, effectSettings: [], upsamplingMode: .precisionSincLinearEco, strategy: .immediateStreaming)
                preconditionFailure("Missing streaming source succeeded")
            } catch let failure as AudioPreparationFailure {
                precondition(failure.stage == .streamingOpen && failure.reason == .preparationFailed)
                log("PASS: requested Precision Sinc still reports actual streaming_open failure: \(AudioPreparationFailure.diagnostic(failure, fallbackStage: .streamingStart))")
            }
            do {
                try await HiResPlaybackEngine.prepareDiskCache(url: missing, headphoneSpatialSettings: .default, upsamplingMode: .precisionSincLinearEco)
                preconditionFailure("Missing cache source succeeded")
            } catch let failure as AudioPreparationFailure {
                precondition(failure.stage == .offlineOpen && failure.reason == .preparationFailed)
                log("PASS: next-track cache retains offline_open failure instead of manufacturing capacity_exceeded")
            }
            let started = Date()
            try await engine.load(url: source, effectSettings: [], upsamplingMode: .precisionSincLinearEco, strategy: .immediateStreaming)
            precondition(engine.hasTrack && engine.activeUpsamplingMode == .avAudioConverter)
            log("PASS: native ready before quality conversion (\(Int(Date().timeIntervalSince(started)*1000)) ms on simulator)")
            let nativeSnapshot = try await MusicAssetPreparation.playableSnapshot(url: source, passthrough: { _ in
                throw MusicAssetPreparation.Failure.unsupported
            })
            let logicalSource = URL(string: "ipod-library://item/item.caf?id=42")!
            let effects = [RealtimeAudioEffectSetting(kind: .equalizer, isEnabled: true)]
            let opened = try await StreamingAudioFilePreparation.open(url: nativeSnapshot.url)
            // This local AVAudioPlayer stands in for the old audible source;
            // only physical-device validation can exercise the Music daemon.
            let oldSource = try AVAudioPlayer(contentsOf: source)
            precondition(oldSource.play())
            try await Task.sleep(for: .milliseconds(100))
            let handoffID = UUID()
            try await engine.loadOpenedFile(url: logicalSource, opened: opened, effectSettings: effects,
                                           headphoneSpatialSettings: .default, mixedHandoff: handoffID)
            precondition(oldSource.isPlaying && engine.hasTrack && engine.currentAudioURL == logicalSource)
            precondition(AVAudioSession.sharedInstance().categoryOptions.contains(.mixWithOthers))
            try engine.seek(to: oldSource.currentTime)
            try engine.play(fadeInDuration: 0.012)
            try await engine.waitForSystemHandoffRender()
            precondition(oldSource.isPlaying && engine.isPlaying)
            let renderedBeforeTransfer = engine.currentTime()
            oldSource.pause()
            try await PlaybackAudioSession.shared.finishMixedHandoff(handoffID)
            precondition(!AVAudioSession.sharedInstance().categoryOptions.contains(.mixWithOthers))
            precondition(engine.isPlaying && engine.currentTime() >= renderedBeforeTransfer)
            log("PASS: old source remains playing through graph startup and first render; session commit preserves the running node")
            try await Task.sleep(for: .milliseconds(400))
            precondition(engine.isPlaying && engine.currentTime() > 0)
            var observedEnabledEffect = false
            for _ in 0..<20 {
                observedEnabledEffect = engine.refreshEffectLevelAudits().contains { $0.kind == .equalizer && $0.isEnabled }
                if observedEnabledEffect { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            precondition(observedEnabledEffect)
            log("PASS: decoded fallback resumes with fade-in and a live enabled EQ, retaining the Music asset identity")
            // Exercise real production transport, including cancellation before
            // the old fade's delayed physical pause can run.
            let beforePause = engine.currentTime()
            engine.pause()
            precondition(!engine.isPlaying && graph.isRunning)
            let frozenPause = engine.currentTime()
            try await Task.sleep(for: .milliseconds(5))
            precondition(engine.currentTime() == frozenPause)
            try engine.play()
            try await Task.sleep(for: .milliseconds(150))
            precondition(engine.isPlaying && graph.mainMixerNode.outputVolume == 1)
            precondition(engine.currentTime() > beforePause)
            log("PASS: rapid pause/resume preserves the live schedule and rejects the stale physical pause")
            engine.pause()
            try await Task.sleep(for: .milliseconds(150))
            precondition(!engine.isPlaying && !graph.isRunning && graph.mainMixerNode.outputVolume == 0)
            try engine.seek(to: 1)
            precondition(!engine.isPlaying && abs(engine.currentTime() - 1) < 0.01)
            try engine.play()
            precondition(graph.mainMixerNode.outputVolume == 0)
            try await engine.waitForSystemHandoffRender()
            precondition(graph.mainMixerNode.outputVolume == 1)
            log("PASS: pause drains at zero; paused seek and default resume restore output only after render startup")
            try engine.seek(to: 4)
            try await Task.sleep(for: .milliseconds(5))
            engine.pause()
            try await Task.sleep(for: .milliseconds(150))
            precondition(!engine.isPlaying && !graph.isRunning && graph.mainMixerNode.outputVolume == 0)
            try engine.play()
            try await engine.waitForSystemHandoffRender()
            log("PASS: pause cancels an in-flight seek without restarting or leaving output muted on resume")
            let beforeFailedUpgrade = engine.currentTime()
            do {
                try await engine.seamlessUpgrade(url: logicalSource, preparationURL: missing,
                    effectSettings: effects, headphoneSpatialSettings: .default,
                    upsamplingMode: .precisionSincLinearEco, shouldResume: true)
                preconditionFailure("Missing quality source succeeded")
            } catch let failure as AudioPreparationFailure {
                precondition(failure.stage == .offlineOpen && failure.reason == .preparationFailed)
                precondition(engine.isPlaying && engine.currentTime() >= beforeFailedUpgrade)
                log("PASS: failed Precision Sinc source preparation retains its stage and leaves native playback running")
            }
            try engine.seek(to: 2)
            try await Task.sleep(for: .milliseconds(150))
            let inputBeforeUpgrade = gainEQ.globalGain
            let automaticBeforeUpgrade = automaticEQ.bands.map(\.gain)
            var sampledLatestSettings = false
            let snapshot = nativeSnapshot
            let upgrade = { @MainActor () async throws in
                try await engine.seamlessUpgrade(url: logicalSource, preparationURL: snapshot.url,
                    latestEffectSettings: { sampledLatestSettings = true; return effects },
                    effectSettings: [], headphoneSpatialSettings: .default,
                    upsamplingMode: .precisionSincLinearEco, shouldResume: true)
            }
            do { try await upgrade() }
            catch is CancellationError {
                // A loaded simulator can take longer than this 20-second fixture
                // to prepare PCM. Only accept the existing EOF safety deferral;
                // restart the test source and retry once using the completed cache.
                guard engine.currentTime() >= engine.duration - 0.25 else { throw CancellationError() }
                log("PASS: preparation reaching fixture EOF safely defers the handoff")
                for _ in 0..<100 {
                    if await HiResPlaybackEngine.preparedAudioCacheStatistics().entryCount > 0 { break }
                    try await Task.sleep(for: .milliseconds(50))
                }
                let preparedCache = await HiResPlaybackEngine.preparedAudioCacheStatistics()
                precondition(preparedCache.entryCount > 0)
                try engine.seek(to: 2); try engine.play()
                try await Task.sleep(for: .milliseconds(100))
                try await upgrade()
            }
            try await Task.sleep(for: .milliseconds(300))
            precondition(engine.isPlaying && engine.currentTime() >= 2 && sampledLatestSettings)
            precondition(engine.activeUpsamplingMode == .precisionSincLinearEco)
            precondition(abs(gainEQ.globalGain - inputBeforeUpgrade) < 0.0001)
            precondition(automaticEQ.bands.map(\.gain) == automaticBeforeUpgrade)
            // A later explicit effect update must not accidentally activate the
            // new analysis as normalization for the same track.
            var changedEffects = effects
            changedEffects[0].parameters["preamp"] = -1
            engine.apply(effectSettings: changedEffects)
            try await Task.sleep(for: .milliseconds(150))
            precondition(abs(gainEQ.globalGain - inputBeforeUpgrade) < 0.0001)
            log("PASS: quality handoff preserves input gain and automatic EQ, including a subsequent effect edit")
            log("PASS: audible native stream upgrades without resetting the seek position; latest effects sampled at commit")
            for rapidResume in [false, true] {
                try await upgrade()
                if rapidResume {
                    let incoming = field(field("isUpgradePlayerNodeActive", as: Bool.self) ? "upgradePlayerNode" : "playerNode", as: AVAudioPlayerNode.self)
                    for _ in 0..<150 {
                        if let stamp = incoming.lastRenderTime,
                           let time = incoming.playerTime(forNodeTime: stamp), time.sampleTime >= 480 { break }
                        try await Task.sleep(for: .milliseconds(1))
                    }
                }
                let handoff = Mirror(reflecting: engine).children.first { $0.label == "pendingHandoff" }!.value
                precondition(!Mirror(reflecting: handoff).children.isEmpty)
                engine.pause()
                if rapidResume {
                    try await Task.sleep(for: .milliseconds(5))
                    try engine.play()
                }
                try await Task.sleep(for: .milliseconds(200))
                precondition(engine.isPlaying == rapidResume)
                if !rapidResume {
                    precondition(!graph.isRunning && graph.mainMixerNode.outputVolume == 0)
                    try engine.play()
                    try await engine.waitForSystemHandoffRender()
                }
                precondition(graph.mainMixerNode.outputVolume == 1 && abs(gainEQ.globalGain - inputBeforeUpgrade) < 0.0001)
            }
            log("PASS: pause before incoming start and rapid resume during a live quality overlap preserve transport and gain")
            for _ in 0..<100 {
                if await HiResPlaybackEngine.preparedAudioCacheStatistics().entryCount > 0 { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            let currentCache = await HiResPlaybackEngine.preparedAudioCacheStatistics()
            precondition(currentCache.entryCount > 0)
            try await HiResPlaybackEngine.prepareDiskCache(url: next, headphoneSpatialSettings: .default, upsamplingMode: .precisionSincLinearEco)
            let nextCache = await HiResPlaybackEngine.preparedAudioCacheStatistics()
            precondition(nextCache.entryCount >= 2)
            log("PASS: current and following tracks stored in bounded disk cache while playback continues")
            engine.stop()
            let reopened = try await StreamingAudioFilePreparation.open(url: nativeSnapshot.url)
            try await engine.loadOpenedFile(url: logicalSource, opened: reopened, effectSettings: effects, headphoneSpatialSettings: .default)
            try engine.play()
            try await Task.sleep(for: .milliseconds(200))
            let pausedUpgrade = Task { try await engine.seamlessUpgrade(url: logicalSource, preparationURL: nativeSnapshot.url, effectSettings: effects, headphoneSpatialSettings: .default, upsamplingMode: .precisionSincLinearEco, shouldResume: true) }
            engine.pause()
            do { try await pausedUpgrade.value }
            catch is CancellationError {
                precondition(!engine.isPlaying)
                try await Task.sleep(for: .milliseconds(150))
                try await engine.seamlessUpgrade(url: logicalSource, preparationURL: nativeSnapshot.url,
                    effectSettings: effects, headphoneSpatialSettings: .default,
                    upsamplingMode: .precisionSincLinearEco, shouldResume: false)
            }
            precondition(!engine.isPlaying && engine.automaticDSPStatus.cacheHit)
            log("PASS: cached quality reused; completed upgrade cannot resume an explicitly paused track")
            let obsolete = Task { try await engine.seamlessUpgrade(url: logicalSource, preparationURL: nativeSnapshot.url, effectSettings: effects, headphoneSpatialSettings: .default, upsamplingMode: .precisionSincLinearEco, shouldResume: false) }
            await Task.yield()
            engine.stop()
            do { try await obsolete.value; precondition(!engine.hasTrack) } catch is CancellationError { }
            precondition(!engine.hasTrack && !engine.isPlaying)
            log("PASS: stopping invalidates an in-flight quality handoff")
            do { try await engine.waitForSystemHandoffRender(); preconditionFailure("stopped engine reported ready") }
            catch is CancellationError { }
            log("PASS: a cancelled/stopped provisional render cannot report handoff readiness")
            log("COMPLETE")
        } catch { engine.stop(); log("FAIL: \(error)") }
    }
}
