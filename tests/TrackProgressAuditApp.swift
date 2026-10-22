import SwiftUI
import AVFoundation

@main struct TrackProgressAuditApp: App {
    var body: some Scene { WindowGroup { Text("Track progress audit").task { await run() } } }
    @MainActor private func run() async {
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let report = root.appendingPathComponent("native-first-result.txt")
        var lines: [String] = []
        func log(_ text: String) { lines.append(text); try? lines.joined(separator: "\n").write(to: report, atomically: true, encoding: .utf8) }
        func require(_ condition: Bool, _ message: String) throws {
            if !condition { throw NSError(domain: message, code: 1) }
        }
        func wait(_ message: String, until condition: () -> Bool) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(15))
            while !condition() && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
            try require(condition(), message)
        }
        let vm = AudioPlayerViewModel()
        do {
            let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
            let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100 * 3)!
            pcm.frameLength = pcm.frameCapacity
            for channel in 0..<2 { for frame in 0..<Int(pcm.frameLength) {
                pcm.floatChannelData![channel][frame] = Float(sin(Double(frame) * 0.03)) * 0.001
            } }
            var songs: [SystemSong] = []
            for index in 1...2 {
                let url = root.appendingPathComponent("track-progress-\(index).caf")
                do { let file = try AVAudioFile(forWriting: url, settings: format.settings); try file.write(from: pcm) }
                songs.append(SystemSong(id: UInt64(index), title: "Audit \(index)", artist: "Audit", album: "Audit",
                    artistID: nil, albumID: nil, discNumber: nil, trackNumber: index, duration: 3, url: url))
            }
            if vm.isAlbumRepeatEnabled { vm.toggleAlbumRepeat() }
            if vm.isSingleTrackRepeatEnabled { vm.toggleSingleTrackRepeat() }
            vm.playSystemQueue(songs, startAt: 0, title: nil)
            try await wait("first track never started") { vm.isPlaying && vm.lyricsPlaybackTime > 0.1 }
            let engine = Mirror(reflecting: vm).children.first {
                $0.label?.contains("hiResPlaybackEngine") == true
            }!.value as! HiResPlaybackEngine
            // Drop the real engine's UI completion delivery. The production
            // timer must consume retained EOF and drive the actual queue.
            engine.onPlaybackEnded = nil
            try await wait("missing callback stranded next track") { vm.isSongActive(songs[1]) && vm.isPlaying }
            log("PASS: real ViewModel/engine reaches next song with completion delivery removed")
            try await wait("final track did not stop") { !vm.isPlaying && vm.progress == 1 }
            log("PASS: real queue stops at final EOF with repeat off")

            vm.toggleSingleTrackRepeat()
            vm.playSystemQueue([songs[0]], startAt: 0, title: nil)
            try await wait("repeat source not started") { vm.isPlaying && vm.lyricsPlaybackTime > 1.5 }
            let repeatSchedule = engine.playbackScheduleID
            try await wait("repeat-one did not reschedule") {
                engine.playbackScheduleID > repeatSchedule && vm.isPlaying && vm.lyricsPlaybackTime < 1
            }
            log("PASS: real repeat-one restarts through the timer without a completion delivery")
            vm.toggleSingleTrackRepeat()
            vm.toggleAlbumRepeat()
            vm.playSystemQueue(songs, startAt: 1, title: nil)
            try await wait("album last song not started") { vm.isSongActive(songs[1]) && vm.isPlaying }
            try await wait("album did not wrap") { vm.isSongActive(songs[0]) && vm.isPlaying }
            log("PASS: real album repeat wraps from last song to first")
            vm.togglePlayback()
            try await Task.sleep(for: .milliseconds(150))
            try require(!vm.isPlaying, "pause overridden")
            log("COMPLETE")
        } catch { log("FAIL: \(error)") }
    }
}
