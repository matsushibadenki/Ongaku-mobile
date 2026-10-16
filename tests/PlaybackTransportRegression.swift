import Foundation

@main
struct PlaybackTransportRegression {
    static func main() {
        var recovery = SystemAssetRecoveryGate()
        precondition(recovery.begin(songID: 42, generation: 1))
        for _ in 0..<500 { precondition(!recovery.begin(songID: 42, generation: 1)) }
        precondition(recovery.begin(songID: 43, generation: 1)) // Music advances without a new app selection.
        precondition(!recovery.begin(songID: 43, generation: 1))
        precondition(recovery.begin(songID: 43, generation: 2)) // Explicit re-selection of the same track.
        recovery.reset() // Pause/background cancellation or explicit retry.
        precondition(recovery.begin(songID: 43, generation: 2))
        print("PASS: observed starts run once; automatic advancement, re-selection and cancellation/retry re-arm recovery")
        for preparing in [false, true] {
            for libraryLoading in [false, true] {
                precondition(!PlaybackTransportPolicy.controlsBlocked(nativeReady: true,
                    preparing: preparing, initialLibraryLoading: libraryLoading))
            }
        }
        precondition(PlaybackTransportPolicy.controlsBlocked(nativeReady: false, preparing: true, initialLibraryLoading: false))
        precondition(PlaybackTransportPolicy.controlsBlocked(nativeReady: false, preparing: false, initialLibraryLoading: true))
        precondition(!PlaybackTransportPolicy.controlsBlocked(nativeReady: false, preparing: false, initialLibraryLoading: false))
        print("PASS: native readiness unlocks controls before quality work and playback observation finish")

        var interrupted = PlaybackTransportPolicy.interruptionRemainsActive(after: .began)
        precondition(interrupted)
        precondition(!PlaybackTransportPolicy.requestIsCurrent(pauseToken: 1, currentPauseToken: 1,
            preparationToken: 2, currentPreparationToken: 2, interrupted: interrupted, cancelled: false))
        // No ended notification: an explicit user play must still reach activation.
        interrupted = PlaybackTransportPolicy.interruptionRemainsActive(after: .explicitPlay)
        precondition(!interrupted)
        precondition(PlaybackTransportPolicy.requestIsCurrent(pauseToken: 1, currentPauseToken: 1,
            preparationToken: 2, currentPreparationToken: 2, interrupted: interrupted, cancelled: false))
        // A new real interruption after the tap must stop the pending request.
        interrupted = PlaybackTransportPolicy.interruptionRemainsActive(after: .began)
        precondition(interrupted)
        precondition(!PlaybackTransportPolicy.interruptionRemainsActive(after: .ended))
        precondition(!PlaybackTransportPolicy.mayResume(osRecommended: false, otherAudioPlaying: true))
        print("PASS: explicit play can reactivate without interruption end; new interruptions still block pending playback")

        precondition(!PlaybackTransportPolicy.shouldPublishNowPlaying(systemSource: true,
            force: true, trackChanged: true, stateChanged: true, elapsedDelta: 10))
        precondition(!PlaybackTransportPolicy.shouldPublishNowPlaying(systemSource: false,
            force: false, trackChanged: false, stateChanged: false, elapsedDelta: 0.25))
        precondition(PlaybackTransportPolicy.shouldPublishNowPlaying(systemSource: false,
            force: false, trackChanged: false, stateChanged: true, elapsedDelta: 0.25))
        precondition(PlaybackTransportPolicy.shouldPublishNowPlaying(systemSource: false,
            force: false, trackChanged: false, stateChanged: false, elapsedDelta: 5))
        print("PASS: Music owns its Now Playing metadata; local progress avoids per-tick publication")
        precondition(PlaybackTransportPolicy.requiresSystemPlayer(protectedAsset: true, hasAssetURL: true))
        precondition(PlaybackTransportPolicy.requiresSystemPlayer(protectedAsset: true, hasAssetURL: false))
        precondition(PlaybackTransportPolicy.requiresSystemPlayer(protectedAsset: false, hasAssetURL: false))
        precondition(!PlaybackTransportPolicy.requiresSystemPlayer(protectedAsset: false, hasAssetURL: true))
        print("PASS: DRM never enters the PCM decoder even when an asset URL exists")

        func matches(_ id: UInt64, _ store: String, expectedStore: String = "12345") -> Bool {
            PlaybackTransportPolicy.systemItemsMatch(expectedID: 42, expectedStoreID: expectedStore,
                observedID: id, observedStoreID: store)
        }
        precondition(matches(42, ""))
        precondition(matches(73, "12345"))
        precondition(matches(0, "12345"))
        precondition(!matches(73, "67890"))
        precondition(!matches(73, "", expectedStore: ""))
        precondition(!matches(73, "0", expectedStore: "0"))
        print("PASS: store identity tolerates library-ID changes without accepting another track")

        let alert = PlaybackErrorPresentationRequest(message: "failure", isActive: true)
        precondition(alert.shouldPresent(currentMessage: "failure", isActive: true, cancelled: false))
        precondition(!alert.shouldPresent(currentMessage: nil, isActive: true, cancelled: false))
        precondition(!alert.shouldPresent(currentMessage: "new failure", isActive: true, cancelled: false))
        precondition(!alert.shouldPresent(currentMessage: "failure", isActive: false, cancelled: false))
        precondition(!alert.shouldPresent(currentMessage: "failure", isActive: true, cancelled: true))
        precondition(!PlaybackErrorPresentationRequest(message: "failure", isActive: false)
            .shouldPresent(currentMessage: "failure", isActive: true, cancelled: false))
        print("PASS: alert delivery rejects cleared, superseded, inactive and cancelled recovery errors")

        func action(ready: Bool = false, played: Bool = false, playing: Bool = false,
                    failed: Bool = false, expired: Bool = false) -> PlaybackTransportPolicy.SystemStartupAction {
            PlaybackTransportPolicy.systemStartupAction(confirmed: playing, prepared: ready,
                preparationFailed: failed, playIssued: played, deadlineReached: expired)
        }
        precondition(action() == .wait)
        precondition(action(ready: true) == .play)
        precondition(action(ready: true, played: true) == .wait)
        precondition(action(ready: true, played: true, playing: true) == .complete)
        precondition(action(failed: true) == .preparationFailed)
        precondition(action(expired: true) == .timedOut) // callback never arrived
        precondition(action(ready: true, played: true, expired: true) == .timedOut)
        precondition(action(playing: true, failed: true, expired: true) == .complete)
        print("PASS: DRM startup waits for preparation, plays once, and terminates on success/error/timeout")

        func accepts(_ observed: UInt64?, starting: Bool = true, system: Bool = true) -> Bool {
            PlaybackTransportPolicy.acceptsSystemObservation(systemSource: system,
                starting: starting, selectedSongID: 42, observedSongID: observed)
        }
        precondition(!accepts(17))
        precondition(!accepts(nil))
        precondition(accepts(42))
        precondition(!accepts(42, system: false))
        precondition(accepts(17, starting: false)) // Real system auto-advance.
        print("PASS: stale DRM notifications cannot overwrite a new selection; auto-advance remains valid")

        func confirmed(_ observed: UInt64?, playing: Bool = true,
                       interrupted: Bool = false, paused: Bool = false) -> Bool {
            PlaybackTransportPolicy.systemStartConfirmed(expectedSongID: 42,
                observedSongID: observed, playing: playing,
                interrupted: interrupted, explicitlyPaused: paused)
        }
        precondition(confirmed(42))
        precondition(!confirmed(17))
        precondition(!confirmed(nil))
        precondition(!confirmed(42, playing: false))
        precondition(!confirmed(42, interrupted: true))
        precondition(!confirmed(42, paused: true))
        print("PASS: loading ends only for the requested, actually playing system track")

        precondition(!PlaybackTransportPolicy.isPlaying(nodePlaying: true, engineRunning: false,
                                                        interrupted: false, explicitlyPaused: false))
        precondition(!PlaybackTransportPolicy.isPlaying(nodePlaying: true, engineRunning: true,
                                                        interrupted: true, explicitlyPaused: false))
        precondition(PlaybackTransportPolicy.isPlaying(nodePlaying: true, engineRunning: true,
                                                       interrupted: false, explicitlyPaused: false))
        print("PASS: stopped engines and interruptions cannot publish playing")

        precondition(!PlaybackTransportPolicy.shouldEnforcePause(explicitlyPaused: false,
                        interrupted: false, starting: false, recovering: false))
        precondition(!PlaybackTransportPolicy.shouldEnforcePause(explicitlyPaused: true,
                        interrupted: false, starting: false, recovering: true))
        precondition(!PlaybackTransportPolicy.shouldEnforcePause(explicitlyPaused: true,
                        interrupted: false, starting: true, recovering: false))
        precondition(PlaybackTransportPolicy.shouldEnforcePause(explicitlyPaused: true,
                        interrupted: false, starting: false, recovering: false))
        print("PASS: watchdog respects startup/recovery and only enforces explicit pause")

        func current(_ pause: UInt64 = 2, _ preparation: UInt64 = 4,
                     interrupted: Bool = false, cancelled: Bool = false) -> Bool {
            PlaybackTransportPolicy.requestIsCurrent(pauseToken: 2, currentPauseToken: pause,
                preparationToken: 4, currentPreparationToken: preparation,
                interrupted: interrupted, cancelled: cancelled)
        }
        precondition(current())
        precondition(!current(3))
        precondition(!current(2, 5))
        precondition(!current(interrupted: true))
        precondition(!current(cancelled: true))
        print("PASS: pause, song changes, interruption and cancellation invalidate stale play requests")

        precondition(!PlaybackTransportPolicy.mayResume(osRecommended: false, otherAudioPlaying: true))
        precondition(PlaybackTransportPolicy.mayResume(osRecommended: false, otherAudioPlaying: false))
        precondition(PlaybackTransportPolicy.mayResume(osRecommended: true, otherAudioPlaying: false))
        print("PASS: automatic fallback waits for other audio to finish")
    }
}
