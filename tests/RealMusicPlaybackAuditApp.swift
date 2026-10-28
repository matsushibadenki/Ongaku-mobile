import SwiftUI
import AVFoundation

final class MusicAuditCapture: @unchecked Sendable {
    static let shared = MusicAuditCapture()
    private let lock = NSLock()
    private var samples = [Float]()
    private var rate: Double = 0
    private var mixedRates = false
    func capture(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData, buffer.format.channelCount > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        if rate == 0 { rate = buffer.format.sampleRate }
        if rate != buffer.format.sampleRate { mixedRates = true; return }
        let n = Int(buffer.frameLength)
        for i in 0..<n { samples.append(channels[0][i]); samples.append(channels[buffer.format.channelCount > 1 ? 1 : 0][i]) }
    }
    func frameCount() -> Int { lock.lock(); defer { lock.unlock() }; return samples.count / 2 }
    func save(to url: URL) throws -> (Double, Int, Bool) {
        lock.lock(); defer { lock.unlock() }
        try samples.withUnsafeBufferPointer { try Data(buffer: $0).write(to: url) }
        return (rate, samples.count/2, mixedRates)
    }
}

@main struct RealMusicPlaybackAuditApp: App {
    var body: some Scene { WindowGroup { Text("Audio playback audit").task { await run() } } }
    @MainActor private func run() async {
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let report = root.appendingPathComponent("music-audit-result.txt")
        var lines: [String] = []
        func log(_ value: String) { lines.append(value); try? lines.joined(separator: "\n").write(to: report, atomically: true, encoding: .utf8) }
        func wait(_ what: String, _ condition: () -> Bool) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(25))
            while !condition() && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
            if !condition() { throw NSError(domain: what, code: 1) }
        }
        let vm = AudioPlayerViewModel()
        do {
            var songs: [SystemSong] = []
            for i in 0..<2 {
                let url = root.appendingPathComponent("input-\(i).caf")
                let file = try AVAudioFile(forReading: url)
                let duration = Double(file.length) / file.processingFormat.sampleRate
                songs.append(SystemSong(id: UInt64(i+1), title: "Audit \(i)", artist: "Audit", album: "Audit", artistID: nil, albumID: nil, discNumber: nil, trackNumber: i+1, duration: duration, url: url))
            }
            // A separate production engine avoids the ViewModel's own background
            // worker cancelling an explicitly requested diagnostic update.
            let diagnosticEngine = HiResPlaybackEngine()
            let sourceURL = root.appendingPathComponent("input-0.caf")
            do {
                try await diagnosticEngine.load(url: sourceURL, effectSettings: [], upsamplingMode: .precisionSincApodizingEco, strategy: .immediateStreaming)
                try await HiResPlaybackEngine.prepareDiskCache(url: sourceURL, headphoneSpatialSettings: .default, upsamplingMode: .precisionSincApodizingEco)
                try diagnosticEngine.play()
                try await wait("diagnostic source not rendering") { diagnosticEngine.isPlaying && diagnosticEngine.currentTime() > 0.1 }
                log("DIAGNOSTIC-BEFORE frame=\(MusicAuditCapture.shared.frameCount()) diagnostics=\(diagnosticEngine.signalDiagnostics == nil ? "absent" : "present")")
                try await diagnosticEngine.seamlessUpgrade(url: sourceURL, effectSettings: [], headphoneSpatialSettings: .default, upsamplingMode: .precisionSincApodizingEco, shouldResume: true)
                log("UPGRADE frame=\(MusicAuditCapture.shared.frameCount()) diagnostics=\(diagnosticEngine.signalDiagnostics == nil ? "absent" : "present")")
                try await Task.sleep(for: .milliseconds(350))
            } catch { log("UPGRADE-UNAVAILABLE frame=\(MusicAuditCapture.shared.frameCount()) reason=\(type(of: error))") }
            diagnosticEngine.stop()
            try await Task.sleep(for: .milliseconds(400))
            if vm.isAlbumRepeatEnabled { vm.toggleAlbumRepeat() }
            if vm.isSingleTrackRepeatEnabled { vm.toggleSingleTrackRepeat() }
            vm.playSystemQueue(songs, startAt: 0, title: nil)
            try await wait("first track not playing") { vm.isSongActive(songs[0]) && vm.isPlaying && vm.lyricsPlaybackTime > 0.15 }
            let engine = Mirror(reflecting: vm).children.first { $0.label?.contains("hiResPlaybackEngine") == true }!.value as! HiResPlaybackEngine
            log("FIRST frame=\(MusicAuditCapture.shared.frameCount()) diagnostics=\(engine.signalDiagnostics == nil ? "absent" : "present")")
            var diagnosticFrame: Int?
            let deadline = ContinuousClock.now.advanced(by: .seconds(25))
            while (!vm.isSongActive(songs[1]) || !vm.isPlaying) && ContinuousClock.now < deadline {
                if diagnosticFrame == nil && engine.signalDiagnostics != nil { diagnosticFrame = MusicAuditCapture.shared.frameCount() }
                try await Task.sleep(for: .milliseconds(20))
            }
            guard vm.isSongActive(songs[1]) && vm.isPlaying else { throw NSError(domain: "next track did not start", code: 1) }
            log("NEXT frame=\(MusicAuditCapture.shared.frameCount()) diagnostics=\(engine.signalDiagnostics == nil ? "absent" : "present") firstDiagnosticFrame=\(diagnosticFrame.map(String.init) ?? "none")")
            try await wait("final track did not stop") { !vm.isPlaying && vm.progress == 1 }
            try await Task.sleep(for: .milliseconds(200))
            let info = try MusicAuditCapture.shared.save(to: root.appendingPathComponent("captured.f32"))
            guard info.0 > 0 && info.1 > 0 && !info.2 else { throw NSError(domain: "invalid captured PCM or changing format", code: 1) }
            log("OUTPUT rate=\(info.0) frames=\(info.1) channels=2")
            log("COMPLETE")
        } catch { log("FAIL: \(error)") }
    }
}
