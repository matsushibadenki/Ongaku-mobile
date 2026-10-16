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
            try engine.seek(to: 2)
            var sampledLatestSettings = false
            let snapshot = nativeSnapshot
            try await engine.seamlessUpgrade(url: logicalSource, preparationURL: snapshot.url, latestEffectSettings: { sampledLatestSettings = true; return effects },
                effectSettings: [], headphoneSpatialSettings: .default,
                upsamplingMode: .precisionSincLinearEco, shouldResume: true)
            try await Task.sleep(for: .milliseconds(300))
            precondition(engine.isPlaying && engine.currentTime() >= 2 && sampledLatestSettings)
            precondition(engine.activeUpsamplingMode == .precisionSincLinearEco)
            log("PASS: audible native stream upgrades without resetting the seek position; latest effects sampled at commit")
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
            try await pausedUpgrade.value
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
