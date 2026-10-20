# Recovered playback and natural track end — 2026-10-19

The reported case is a Music-managed non-DRM song, resumed with the Play button after another app takes audio while Ongaku is inactive.

## Confirmed defect and repair

A protected seek retains the old source during its fade/drain. If the player node stops before a subsequent `play()` call, that call supersedes the drain with a new transport token. Previously the seek flag remained set, while its only clearing callback was now obsolete. Playback could resume at the old offset and its natural EOF was then suppressed as if a seek were still pending. Timer-based fallback may mask this; the completion callback itself must remain reliable, including in background playback.

Replace the standalone pending flag with a pending seek position. A superseding Play adopts that destination and clears the pending state before creating a replacement schedule. Normal live seek/play still uses the protected drain. Pause and destructive stop discard the pending position, and stale schedule generations remain rejected. CPU conversion, gain and effects policies are unchanged.

The new deterministic test fails on the pre-fix source with `reclaimed playback retained a stranded seek or lost its destination`. This confirms a real matching control-flow defect; it does not establish that every occurrence on the user's device has the same cause.

## Verification

- `bash tests/run_recovered_track_end_regression.sh`: 8 cases using extracted shipping transport and `AudioPlayerViewModel` EOF/queue decision methods. Cover next song, repeat-one at both queue positions, album wrap, final stop with repeat off, stale generations and newer pause/stop. A fault-injection control that retains the pending seek must fail. Queue loading/UI/session dependencies are stubs; this verifies which production action is selected, not actual playback of the next Music asset.
- `bash tests/run_transport_continuity_regression.sh`: 12 transport state groups and 6 real stock-mixer PCM fade cases at 44.1/48/96 kHz; abrupt start/stop and premature resource teardown controls are rejected.
- `bash tests/run_foreground_recovery_regression.sh`: existing 10 recovery groups and the refresh-before-intent negative control pass.
- `bash tests/run_native_first_simulator_audit.sh <iPhone-SE-UUID> --foreground-recovery`: 7 production-engine groups on iOS 26.2. Retained-position recovery, cancellation and teardown pass. For file-backed and prepared PCM playback, explicitly stop the real player node during a seek, resume, confirm progress at the requested destination and require exactly one actual EOF callback. File-backed playback keeps an `ipod-library` logical identity backed by a generated local CAF fixture. This simulates node loss; it does not emulate another app or the Music daemon.
- Ordinary iPhone Simulator Debug build succeeds on Xcode 27.1. Existing settings-tab work is retained.

[Verification output](measurements/recovered-track-end-2026-10-19.txt)

## Pending

On a physical iPhone, play the user's Music-managed non-DRM tracks, move Ongaku to the background, let another app take audio, stop that app and press Play in Ongaku or on the lock screen. Check recovery both mid-track and near EOF, next track, repeat-one, album wrap, repeated interruptions and newer pause/track selection. Confirm speaker audio and button state. Simulator completion and queue-policy results do not replace these checks.
