"""Exercise shipping local EOF/queue decisions with the transport fixture.
Only queue loading, UI and session collaborators are replaced; the completion,
repeat and next-track branching comes directly from AudioPlayerViewModel.
"""
from pathlib import Path
import sys
source = Path('audio/AudioPlayerViewModel.swift').read_text()
def block(anchor):
    assert source.count(anchor) == 1, anchor
    start = source.index(anchor)
    end = source.index('{', start) + 1
    depth = 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end].replace('private ', '')
fixture = '''import Foundation
func CFAbsoluteTimeGetCurrent() -> Double { 1_000 + DispatchQueue.main.seconds }
enum PlaybackSource { case local, system }
enum RepeatMode { case off, singleTrack, album }
enum L10n { static func tr(_ key: String, _ detail: String) -> String { detail } }
final class PlaybackAudioSession {
    static let shared = PlaybackAudioSession()
    var deactivations = 0
    func deactivate() { deactivations += 1 }
}
final class RecoveredQueueHost {
    let hiResPlaybackEngine: ShippingTransportHost
    var playbackSource = PlaybackSource.local
    var isInterrupted = false
    var isInForcedPausedWindow = false
    var interruptionResumeTask: Task<Void, Never>?
    var repeatMode = RepeatMode.off
    var lastTrackEndHandledAt: Double = 0
    var lastLocalTrackEndGeneration: UInt64?
    var unexpectedPlaybackRecoveryTask: Task<Void, Never>?
    var lastUserPlaybackInteractionAt: Double = 0
    var systemQueue = [0, 1]
    var systemQueueIndex: Int? = 0
    var systemQueueTitle: String?
    var queueStarts: [Int] = []
    var completed = 0
    var isPlaying = true
    var timerRunning = true
    var progress = 0.0
    var currentTimeText = ""
    var durationText = ""
    var errorMessage: String?
    init(_ engine: ShippingTransportHost) {
        hiResPlaybackEngine = engine
        engine.onPlaybackEnded = { [weak self] in self?.handleLocalPlaybackEnded() }
    }
    func recordCurrentSystemSongAsCompleted() { completed += 1 }
    func playSystemQueue(_ songs: [Int], startAt index: Int, title: String?) {
        systemQueueIndex = index
        queueStarts.append(index)
    }
    func startTimer() { timerRunning = true }
    func stopTimer() { timerRunning = false }
    func refreshPlaybackState() { isPlaying = hiResPlaybackEngine.isPlaying }
    func beginForcedPausedWindow(for source: PlaybackSource) { isInForcedPausedWindow = true }
    func formatTime(_ time: Double) -> String { String(time) }
    func updateQueueCapabilities() {}
    func updateNowPlayingInfo(force: Bool) {}
    func reinforceNowPlayingTransportState() {}
    func persistLibraryState() {}
'''
for anchor in ['private func handleLocalPlaybackEnded()', 'private func shouldIgnoreDuplicateTrackEndEvent()',
               'private var hasNextTrackInQueue:', 'func playNextTrack()']:
    fixture += '\n' + block(anchor)
Path(sys.argv[1]).write_text(fixture + '\n}\n')
