import Foundation

@main struct ForegroundRecoveryRegression {
    @MainActor static func main() async throws {
        func require(_ value: Bool, _ message: String) throws {
            if !value { throw NSError(domain: message, code: 1) }
        }
        let stopped = ForegroundHost()
        stopped.hiResPlaybackEngine.isPlaying = false
        stopped.hiResPlaybackEngine.isEngineRunning = false
        stopped.handleAppDidBecomeActive()
        try require(stopped.wasPlayingBeforeSessionInterruption && stopped.resumeRequests == 1,
            "foreground erased playback intent before recovery")
        try require(!stopped.isPlaying && !stopped.timerRunning, "stopped source still presented as playing")
        print("PASS: foreground retains pre-refresh playback intent and requests recovery for stopped I/O")

        let stalled = ForegroundHost()
        stalled.hiResPlaybackEngine.stalled = true
        stalled.handleAppDidBecomeActive()
        try require(stalled.resumeRequests == 1 && !stalled.isPlaying, "stale running flags accepted")
        print("PASS: stalled render cannot keep the playing button despite running engine/node flags")

        let missingEnd = ForegroundHost()
        missingEnd.isInterrupted = true
        missingEnd.isPlaying = false
        missingEnd.wasPlayingBeforeSessionInterruption = true
        missingEnd.interruptedPlaybackSource = .local
        missingEnd.handleAppDidBecomeActive()
        try require(!missingEnd.isInterrupted && missingEnd.resumeRequests == 1
            && !missingEnd.interruptionAllowsImmediateResume && !missingEnd.isPlaying,
            "missing interruption end stranded resume intent")
        print("PASS: missing interruption end permits a guarded foreground retry without asserting playback")

        Session.shared.isOtherAudioPlaying = true
        let occupied = ForegroundHost()
        occupied.isInterrupted = true
        occupied.isPlaying = false
        occupied.wasPlayingBeforeSessionInterruption = true
        occupied.interruptedPlaybackSource = .local
        occupied.handleAppDidBecomeActive()
        try require(occupied.isInterrupted && occupied.resumeRequests == 0 && !occupied.isPlaying,
            "foreground took audio from another app")
        Session.shared.isOtherAudioPlaying = false
        occupied.handleAppDidBecomeActive()
        try require(occupied.resumeRequests == 1, "later free session not retried")
        print("PASS: other audio preserves the interruption; a subsequent free foreground can retry")

        for changedTrack in [false, true] {
            let stale = ForegroundHost()
            stale.isInterrupted = true; stale.isPlaying = false
            stale.wasPlayingBeforeSessionInterruption = true
            stale.interruptedPlaybackSource = .local
            if changedTrack { stale.playbackPreparationToken += 1 } else { stale.userPauseIntentToken += 1 }
            stale.handleAppDidBecomeActive()
            try require(stale.resumeRequests == 0 && stale.isInterrupted, "stale intent resumed")
        }
        let paused = ForegroundHost()
        paused.isPlaying = false; paused.hiResPlaybackEngine.isPlaying = false
        paused.handleAppDidBecomeActive()
        try require(paused.resumeRequests == 0, "user pause auto-resumed")
        let forced = ForegroundHost()
        forced.isInForcedPausedWindow = true; forced.hiResPlaybackEngine.isPlaying = false
        forced.handleAppDidBecomeActive()
        try require(forced.resumeRequests == 0, "forced pause auto-resumed")
        print("PASS: user pause and changed track/pause generations reject foreground auto-resume")

        let healthy = ForegroundHost()
        healthy.handleAppDidBecomeActive()
        try require(healthy.resumeRequests == 0 && healthy.isPlaying && healthy.timerRunning,
            "healthy background playback was restarted")
        let music = ForegroundHost()
        music.playbackSource = .system; music.isSystemPlayerConfigured = true
        music.systemPlayer.playbackState = .playing
        music.handleAppDidBecomeActive()
        try require(music.resumeRequests == 0 && music.isPlaying,
            "Music-owned session was recovered as local audio")
        print("PASS: healthy local playback and Music-owned playback retain their existing ownership")

        let recovered = ForegroundHost()
        recovered.wasPlayingBeforeSessionInterruption = true
        recovered.interruptedPlaybackSource = .local
        recovered.hiResPlaybackEngine.isPlaying = false
        recovered.hiResPlaybackEngine.stalled = true
        recovered.runInterruptionResume(source: .local, generation: 0)
        await recovered.interruptionResumeTask?.value
        try require(recovered.hiResPlaybackEngine.confirmationCount == 1
            && recovered.isPlaying && recovered.timerRunning
            && !recovered.wasPlayingBeforeSessionInterruption && recovered.interruptionResumeTask == nil,
            "recovery did not confirm fresh progress before clearing intent")
        print("PASS: production recovery confirms progress, clears pending intent and restores playing UI")

        let failed = ForegroundHost()
        failed.wasPlayingBeforeSessionInterruption = true
        failed.interruptedPlaybackSource = .local
        failed.hiResPlaybackEngine.progressFails = true
        failed.runInterruptionResume(source: .local, generation: 0)
        await failed.interruptionResumeTask?.value
        try require(failed.hiResPlaybackEngine.confirmationCount == 8
            && !failed.isPlaying && !failed.hiResPlaybackEngine.isPlaying
            && failed.wasPlayingBeforeSessionInterruption && failed.interruptionResumeTask == nil,
            "failed recovery accepted stale running flags or lost retry intent")
        failed.handleAppDidBecomeActive()
        try require(failed.resumeRequests == 1, "failed recovery cannot retry on foreground")
        print("PASS: exhausted progress recovery stays paused despite running flags and preserves later retry intent")

        let frozen = ProgressHost()
        do { try await frozen.waitForPlaybackProgress(); throw NSError(domain: "frozen clock accepted", code: 1) }
        catch HiResEngineError.upconvertFailed {}
        let live = ProgressHost(); live.advancing = true
        try await live.waitForPlaybackProgress()
        print("PASS: recovery rejects old render position and confirms fresh advancing source frames")

        let cancelled = ProgressHost()
        let cancelledTask = Task { try await cancelled.waitForPlaybackProgress() }
        cancelledTask.cancel()
        do { try await cancelledTask.value; throw NSError(domain: "cancel ignored", code: 1) }
        catch is CancellationError {}
        let superseded = ProgressHost()
        let waiter = Task { try await superseded.waitForPlaybackProgress() }
        try await Task.sleep(for: .milliseconds(20)); superseded.transportToken += 1
        do { try await waiter.value; throw NSError(domain: "superseded transport accepted", code: 1) }
        catch is CancellationError {}
        print("PASS: cancelled and superseded progress checks cannot confirm a newer playback request")
    }
}
