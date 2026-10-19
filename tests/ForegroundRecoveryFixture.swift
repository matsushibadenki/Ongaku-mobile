import Foundation

enum PlaybackSource { case local, system }
enum MPNowPlayingPlaybackState { case playing, paused }
struct AudioRenderHealthSnapshot { var isStalled = false }
final class Session {
    static let shared = Session()
    var isOtherAudioPlaying = false
    static func sharedInstance() -> Session { shared }
}
typealias AVAudioSession = Session
struct PlaybackDebugLogger {
    static func event(_ value: String) {}
    static func warning(_ value: String) {}
}
struct PlaybackRecoveryBackgroundLease { var expired = false; func end() {} }
final class PlaybackAudioSession {
    static let shared = PlaybackAudioSession()
    var activations = 0
    func activate() async throws { activations += 1 }
}
struct L10n { static func tr(_ key: String, _ argument: String) -> String { argument } }
final class MockEngine {
    var hasTrack = true
    var isPlaying = true
    var isEngineRunning = true
    var isRunning: Bool { isEngineRunning }
    var stalled = false
    var position = 2.0
    var progressFails = false
    var confirmationCount = 0
    func currentTime() -> Double { position }
    func seek(to value: Double) throws { position = value }
    func play() throws { isPlaying = true; isEngineRunning = true }
    func pause() { isPlaying = false; isEngineRunning = false }
    func waitForPlaybackProgress() async throws {
        confirmationCount += 1
        if progressFails { throw HiResEngineError.upconvertFailed }
        position += 0.03; stalled = false
    }
    func pollRenderHealth() -> AudioRenderHealthSnapshot { .init(isStalled: stalled) }
    func setRealtimeAnalysisEnabled(_ value: Bool) {}
}
final class MockSystemPlayer { var playbackState = MPNowPlayingPlaybackState.paused; func play() { playbackState = .playing } }
final class ForegroundHost {
    var playbackSource = PlaybackSource.local
    var isApplicationActive = false
    var hasInitializedHiResPlaybackEngine = true
    var isSystemPlayerConfigured = false
    var isInForcedPausedWindow = false
    var isInterrupted = false
    var isPlaying = true
    var isPlaybackStarting = false
    var isProcessing = false
    var errorMessage: String?
    var wasPlayingBeforeSessionInterruption = false
    var interruptedPlaybackSource: PlaybackSource?
    var userPauseIntentToken: UInt64 = 1
    var playbackPreparationToken: UInt64 = 2
    var interruptionPauseIntentBaseline: UInt64 = 1
    var interruptionPlaybackPreparationBaseline: UInt64 = 2
    var interruptionGeneration: UInt64 = 0
    var interruptionAllowsImmediateResume = false
    var interruptionResumeTask: Task<Void, Never>?
    var unexpectedPlaybackRecoveryTask: Task<Void, Never>?
    let hiResPlaybackEngine = MockEngine()
    let systemPlayer = MockSystemPlayer()
    var audioRenderHealth = AudioRenderHealthSnapshot()
    var resumeRequests = 0
    var timerRunning = false
    func resumePlaybackAfterInterruption(source: PlaybackSource, generation: UInt64) { resumeRequests += 1 }
    func ensureSystemPlayerConfigured() {}
    func syncSystemPlaybackState() { refreshPlaybackState() }
    func clearForcedPausedWindow() { isInForcedPausedWindow = false }
    func refreshPlaybackState() { isPlaying = actualPlaybackState == .playing }
    func flushDeferredLibrarySnapshotIfPlaybackIsIdle(allowWhilePlaying: Bool) {}
    func recoverEmptyLibraryAfterForeground() {}
    func refreshNowPlayingAlbum() {}
    func startTimer() { timerRunning = true }
    func stopTimer(animateMeter: Bool = true) { timerRunning = false }
    func updateNowPlayingInfo(force: Bool) {}
    func resumeAutomaticQualityUpgradeIfNeeded() {}
    func startSystemAssetRecoveryIfNeeded() {}
    func scheduleDeferredSystemLibraryRefresh() {}
    func scheduleLocalLibraryChangeRefresh(delay: Duration) {}
}
enum HiResEngineError: Error { case upconvertFailed }
final class ProgressHost {
    var transportToken: UInt64 = 1
    var transportStopPending = false
    var pendingTransportPause: Double?
    var transportFadeInPending = false
    var transportSeekPending = false
    let engine = MockEngine()
    let activePlayerNode = MockEngine()
    var advancing = false
    let start = ContinuousClock.now
    func currentTime() -> Double {
        let elapsed = start.duration(to: .now).components
        return 7 + (advancing ? Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18 : 0)
    }
}
