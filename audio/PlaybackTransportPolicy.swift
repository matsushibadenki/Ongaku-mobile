import Foundation

/// UI state is an observation, never a request to stop a recovering player.
nonisolated enum PlaybackTransportPolicy {
    enum InterruptionEvent {
        case began
        case ended
        case explicitPlay
    }

    static func interruptionRemainsActive(after event: InterruptionEvent) -> Bool {
        switch event {
        case .began:
            return true
        case .ended, .explicitPlay:
            // A user request may attempt activation. The OS still arbitrates
            // audio ownership (and may reject activation during a call).
            return false
        }
    }

    static func shouldPublishNowPlaying(systemSource: Bool, force: Bool,
                                        trackChanged: Bool, stateChanged: Bool,
                                        elapsedDelta: Double) -> Bool {
        // Music owns the system player's Now Playing session. Publishing a
        // second app-owned session is not a way to synchronize that player.
        guard !systemSource else { return false }
        return force || trackChanged || stateChanged || abs(elapsedDelta) >= 5
    }

    enum SystemStartupAction: Equatable {
        case wait, play, complete, preparationFailed, timedOut
    }

    static func systemStartupAction(confirmed: Bool, prepared: Bool, preparationFailed: Bool,
                                    playIssued: Bool, deadlineReached: Bool) -> SystemStartupAction {
        // A delayed completion/error must never hide actual confirmed playback.
        if confirmed { return .complete }
        if preparationFailed { return .preparationFailed }
        if deadlineReached { return .timedOut }
        if prepared && !playIssued { return .play }
        return .wait
    }

    static func requiresSystemPlayer(protectedAsset: Bool, hasAssetURL: Bool) -> Bool {
        protectedAsset || !hasAssetURL
    }

    /// Store-backed playback can expose a different library ID. Never fall
    /// back to title/artist or accept an empty/placeholder store ID.
    static func systemItemsMatch(expectedID: UInt64, expectedStoreID: String,
                                 observedID: UInt64, observedStoreID: String) -> Bool {
        if expectedID != 0 && expectedID == observedID { return true }
        return !expectedStoreID.isEmpty && expectedStoreID != "0"
            && expectedStoreID == observedStoreID
    }

    /// MediaPlayer can keep reporting the old item while a new queue is pending.
    /// Observations must not replace the identity of an in-flight user request.
    static func acceptsSystemObservation(systemSource: Bool, starting: Bool,
                                         selectedSongID: UInt64?, observedSongID: UInt64?) -> Bool {
        guard systemSource else { return false }
        return !starting || (selectedSongID != nil && selectedSongID == observedSongID)
    }

    static func systemStartConfirmed(expectedSongID: UInt64?, observedSongID: UInt64?,
                                     playing: Bool, interrupted: Bool, explicitlyPaused: Bool) -> Bool {
        expectedSongID != nil && expectedSongID == observedSongID
            && playing && !interrupted && !explicitlyPaused
    }

    static func mayResume(osRecommended: Bool, otherAudioPlaying: Bool) -> Bool {
        osRecommended || !otherAudioPlaying
    }

    static func isPlaying(nodePlaying: Bool, engineRunning: Bool,
                          interrupted: Bool, explicitlyPaused: Bool) -> Bool {
        nodePlaying && engineRunning && !interrupted && !explicitlyPaused
    }

    static func shouldEnforcePause(explicitlyPaused: Bool, interrupted: Bool,
                                   starting: Bool, recovering: Bool) -> Bool {
        explicitlyPaused && !interrupted && !starting && !recovering
    }

    static func requestIsCurrent(pauseToken: UInt64, currentPauseToken: UInt64,
                                 preparationToken: UInt64, currentPreparationToken: UInt64,
                                 interrupted: Bool, cancelled: Bool) -> Bool {
        pauseToken == currentPauseToken && preparationToken == currentPreparationToken
            && !interrupted && !cancelled
    }
}
