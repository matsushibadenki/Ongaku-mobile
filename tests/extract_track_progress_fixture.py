"""Exercise production timer/tick/queue branching; virtualize only OS/engine time."""
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
import AppKit
enum PlaybackSource { case local, system }
enum RepeatMode { case off, singleTrack, album }
enum PlayerState { case playing, stopped }
enum L10n { static func tr(_ key: String, _ detail: String) -> String { detail } }
struct Health: Equatable { var isStalled = false }
enum PlaybackDebugLogger { static func event(_ text: String) {} }
final class PlaybackAudioSession { static let shared = PlaybackAudioSession(); func deactivate() {} }
final class ProgressEngine {
    var hasTrack = true, isPlaying = true, isEngineRunning = true, hasReachedPlaybackEnd = false
    var duration = 10.0, position = 0.0
    var playbackScheduleID: UInt64 = 1
    var health = Health()
    func currentTime() -> Double { position }
    func pollRenderHealth() -> Health { health }
    func seek(to value: Double) throws { position = value; playbackScheduleID += 1; hasReachedPlaybackEnd = false }
    func play() throws { isPlaying = true }
    func pause() { isPlaying = false; hasReachedPlaybackEnd = false }
}
final class SystemPlayer { var currentPlaybackTime = 0.0; var playbackState = PlayerState.playing }
final class ProgressQueueHost {
    var now = 100.0
    var playbackSource = PlaybackSource.local
    var isInterrupted = false, isPlaying = true, isInForcedPausedWindow = false
    var isPlaybackStarting = false, isSystemPlayerStarting = false, isSystemPlayerConfigured = false
    var hasInitializedHiResPlaybackEngine = true, isSystemPlaybackAtTrackEnd = false
    var interruptionResumeTask: Int?, unexpectedPlaybackRecoveryTask: Int?
    var memorySafetyTickCount = 0
    let hiResPlaybackEngine = ProgressEngine(), systemPlayer = SystemPlayer()
    var audioRenderHealth = Health()
    var localProgressWatchdog = PlaybackProgressWatchdog()
    var lastLocalTrackEndGeneration: UInt64?
    var repeatMode = RepeatMode.off
    var systemQueue = [0, 1]
    var systemQueueIndex: Int? = 0
    var systemQueueTitle: String?
    var lastUserPlaybackInteractionAt = 0.0
    var queueStarts: [Int] = [], recoveryReasons: [String] = []
    var completed = 0
    var progress = 0.0
    var currentTimeText = "", durationText = ""
    var errorMessage: String?
    var timerRunning = true
    func CFAbsoluteTimeGetCurrent() -> Double { now }
    func applyProactiveMemorySafetyIfNeeded() {}
    func refreshPlaybackState() { isPlaying = hiResPlaybackEngine.isPlaying }
    func runPlaybackWatchdog() {}
    func handleSystemPlaybackEnded() {}
    func scheduleUnexpectedLocalPlaybackRecovery(reason: String) {
        guard unexpectedPlaybackRecoveryTask == nil else { return }
        recoveryReasons.append(reason); unexpectedPlaybackRecoveryTask = 1
    }
    func recordCurrentSystemSongAsCompleted() { completed += 1 }
    func playSystemQueue(_ songs: [Int], startAt index: Int, title: String?) {
        systemQueueIndex = index; queueStarts.append(index)
        try! hiResPlaybackEngine.seek(to: 0)
    }
    func startTimer() { timerRunning = true }
    func stopTimer() { timerRunning = false; localProgressWatchdog.reset() }
    func beginForcedPausedWindow(for source: PlaybackSource) { isInForcedPausedWindow = true }
    func formatTime(_ time: Double) -> String { String(time) }
    func updateQueueCapabilities() {}
    func updateNowPlayingInfo(force: Bool) {}
    func reinforceNowPlayingTransportState() {}
    func persistLibraryState() {}
'''
for anchor in ['@objc private func handleTimerTick()', 'private func handleLocalPlaybackEnded()',
               'private var hasNextTrackInQueue:', 'func playNextTrack()']:
    method = block(anchor).replace('@objc ', '').replace('ProcessInfo.processInfo.systemUptime', 'now')
    if '--no-source-watchdog' in sys.argv:
        method = method.replace(' || sourceStalled)', ')')
    fixture += '\n' + method
fixture += '''\n}
final class ProgressTimerHost: NSObject {
    var updateTimer: Timer?
    var ticks = 0
    @objc func handleTimerTick() { ticks += 1 }
    func cancelLibraryWorkForPlayback() {}
    func stopTimer(animateMeter: Bool) { updateTimer?.invalidate(); updateTimer = nil }
    func startVisualizationTimer() {}
'''
method = block('private func startTimer()')
if '--default-mode-timer' in sys.argv:
    method = method.replace('RunLoop.main.add(updateTimer, forMode: .common)', 'RunLoop.main.add(updateTimer, forMode: .default)')
fixture += method + '\n}\n'
Path(sys.argv[1]).write_text(fixture)
