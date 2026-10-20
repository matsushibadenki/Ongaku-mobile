import SwiftUI
import AVFoundation

@main struct ForegroundRecoveryAuditApp: App {
    var body: some Scene { WindowGroup { Text("Foreground recovery audit").task { await run() } } }
    @MainActor private func run() async {
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let report = root.appendingPathComponent("native-first-result.txt")
        var lines: [String] = []
        func log(_ text: String) { lines.append(text); try? lines.joined(separator: "\n").write(to: report, atomically: true, encoding: .utf8) }
        let engine = HiResPlaybackEngine()
        let graph = Mirror(reflecting: engine).children.first { $0.label == "engine" }!.value as! AVAudioEngine
        do {
            let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
            let source = root.appendingPathComponent("foreground-source.caf")
            let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100 * 10)!
            pcm.frameLength = pcm.frameCapacity
            for channel in 0..<2 { for frame in 0..<Int(pcm.frameLength) {
                pcm.floatChannelData![channel][frame] = Float(sin(Double(frame) * 0.03)) * 0.015
            } }
            do { let file = try AVAudioFile(forWriting: source, settings: format.settings); try file.write(from: pcm) }
            let logicalURL = URL(string: "ipod-library://item/foreground.caf?id=109")!
            let opened = try await StreamingAudioFilePreparation.open(url: source)
            try await engine.loadOpenedFile(url: logicalURL, opened: opened,
                effectSettings: [.init(kind: .equalizer, isEnabled: true)], headphoneSpatialSettings: .default)
            try engine.seek(to: 2)
            try engine.play()
            try await engine.waitForPlaybackProgress()
            precondition(engine.isPlaying && engine.currentTime() > 2.02)
            log("PASS: native Music-identity source confirms fresh progress after protected startup")

            let retainedPosition = engine.currentTime()
            graph.pause() // Simulate lost I/O; this does not emulate the media daemon.
            precondition(!engine.isPlaying && engine.hasTrack)
            do { try await engine.waitForPlaybackProgress(); preconditionFailure("stopped I/O confirmed") }
            catch is CancellationError {}
            precondition(engine.currentAudioURL == logicalURL)
            log("PASS: stopped render I/O cannot report recovery while Music identity and resource remain retained")

            try await PlaybackAudioSession.shared.activate()
            try engine.seek(to: engine.currentTime())
            try engine.play()
            try await engine.waitForPlaybackProgress()
            precondition(engine.isPlaying && engine.isEngineRunning)
            precondition(engine.currentTime() >= retainedPosition && engine.currentTime() < retainedPosition + 1)
            precondition(engine.currentAudioURL == logicalURL && !engine.pollRenderHealth().isStalled)
            log("PASS: reactivation and protected rescheduling resume from retained position without replacing Music identity")

            let waiting = Task { @MainActor in try await engine.waitForPlaybackProgress() }
            await Task.yield()
            engine.pause()
            do { try await waiting.value; preconditionFailure("pause accepted as recovery") }
            catch is CancellationError {}
            try await Task.sleep(for: .milliseconds(100))
            precondition(!engine.isPlaying)
            log("PASS: a newer pause cancels pending recovery confirmation and remains paused")
            try engine.play()
            try await engine.waitForPlaybackProgress()
            for preparedPCM in [false, true] {
                if preparedPCM {
                    try await engine.load(url: source, effectSettings: [],
                        upsamplingMode: .avAudioConverter, skipDSPAnalysis: true)
                    try engine.play()
                    try await engine.waitForPlaybackProgress()
                }
                var completions = 0
                engine.onPlaybackEnded = { completions += 1 }
                try engine.seek(to: engine.duration - 0.4)
                // Deterministically invalidate the source during the protected
                // seek. This models node loss, not another app's real session.
                let activeIsUpgrade = Mirror(reflecting: engine).children.first {
                    $0.label == "isUpgradePlayerNodeActive"
                }!.value as! Bool
                let nodeName = activeIsUpgrade ? "upgradePlayerNode" : "playerNode"
                let node = Mirror(reflecting: engine).children.first { $0.label == nodeName }!.value as! AVAudioPlayerNode
                node.stop()
                try engine.play()
                try await engine.waitForPlaybackProgress()
                precondition(engine.currentTime() > engine.duration - 0.5)
                let deadline = ContinuousClock.now.advanced(by: .seconds(2))
                while completions == 0 && ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(10))
                }
                precondition(completions == 1, "reclaimed source lost or duplicated EOF")
                try await Task.sleep(for: .milliseconds(100))
                precondition(completions == 1)
                log("PASS: explicit resume after lost seek node delivers one EOF, preparedPCM=\(preparedPCM)")
                engine.pause()
                try await Task.sleep(for: .milliseconds(100))
                completions = 0
                try engine.seek(to: engine.duration - 0.01)
                try engine.play()
                try await engine.waitForPlaybackProgress()
                precondition(engine.hasReachedPlaybackEnd && completions == 1,
                             "short tail failed recovery confirmation")
                try await engine.waitForPlaybackProgress()
                precondition(completions == 1)
                log("PASS: 10 ms tail confirms recovery through one retained EOF, preparedPCM=\(preparedPCM)")
                engine.onPlaybackEnded = nil
            }
            let stopped = engine.stop()
            try await engine.waitForStop(generation: stopped)
            precondition(!engine.hasTrack && !graph.isRunning)
            log("PASS: explicit resume still advances and destructive stop still drains after recovery")
            log("COMPLETE")
        } catch { engine.stop(); log("FAIL: \(error)") }
    }
}
