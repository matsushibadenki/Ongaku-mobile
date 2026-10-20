# Track-end follow-up — 2026-10-20

The user reports intermittent silence at the end of a song, with the previous song still selected and the Pause button still shown. Previously confirmed context was Music-managed non-DRM playback resumed using Play after another app took audio. The latest reply did not establish whether this occurrence followed an interruption or ordinary playback.

## Confirmed defects and changes

1. **A rejected quality replacement could disable the audible prepared source's EOF.** Prepared player callbacks shared a global attempt token. Starting another attempt invalidated the older callback even when scheduling missed its deadline or rejected an invalid tail. The token is now retained per player node. Rejection invalidates only the candidate; ordinary replacement retires that node's prepared token. Playback generation continues to reject outgoing callbacks after a successful handoff.
2. **Recovery could discard natural EOF.** The ViewModel ignored EOF while an interruption-resume task owned playback. If a short remaining tail ended during progress confirmation, no later owner reliably delivered the queue transition. The engine now retains and deduplicates accepted EOF by schedule generation, records the final position and retires render-health monitoring. A valid EOF satisfies recovery even when the remaining source is too short to meet the 20 ms advancing-position threshold. Cancellation and newer pause/stop checks still take priority.
3. **Deferred EOF now has an explicit delivery path.** Interruption recovery and unexpected-stop recovery release ownership before invoking the existing next/repeat handler. Timer fallback also sees retained EOF even when a UI refresh has cleared `isPlaying`. Local queue handling uses schedule identity instead of a global 350 ms debounce, so duplicates are suppressed without losing a different short track or repeat. System-player debounce remains unchanged.

These are verified code defects matching possible failure paths, not proof of the cause of every occurrence on the user's iPhone. No CPU conversion, DSP gain, effect-tail or transport envelope policy was changed.

## Verification

- Before the fix, the new recovery test failed with `EOF during recovery was discarded instead of delivered after clearing recovery`.
- `bash tests/run_prepared_eof_regression.sh`: 3 groups extracting the shipping prepared scheduling method, commit/deadline decision and EOF handler. Reject a deadline miss and invalid tail without losing the audible prepared source's EOF; reject duplicate callbacks, a candidate callback after generation reuse and outgoing EOF after successful replacement. A negative control restoring the global callback gate fails. Player callback timing is virtualized; these tests do not measure real handoff audio.
- `bash tests/run_recovered_track_end_regression.sh`: 10 cases using shipping transport and local queue decision methods. Preserve next song, repeat-one at both queue positions, album wrap, final stop, stale-generation rejection and newer pause/stop. Retain EOF through both recovery owners and stale UI state, deliver once, then accept a different schedule ending within 350 ms. The previous stranded-seek negative control remains rejected. Queue loading is stubbed: these tests establish the selected queue action, not playback of real Music assets.
- `bash tests/run_foreground_recovery_regression.sh`: 13 groups. Exercise shipping interruption and unexpected-stop recovery, retained short-tail completion, stale progress, exhausted retries and cancellation. Both refresh-before-intent and discarded-EOF negative controls fail as intended. Session/player collaborators are mocked.
- `bash tests/run_transport_continuity_regression.sh`: 12 transport groups and 6 real stock-mixer PCM fade cases at 44.1/48/96 kHz pass; abrupt-source and early-resource-release controls remain rejected. Existing fixture-only unused-result warnings are not app build failures.
- `bash tests/run_native_first_simulator_audit.sh 8220EDC1-4303-49BF-B480-0484AC2BBB47 --foreground-recovery`: 9 production-engine groups pass on iPhone SE / iOS 26.2. Actual file-backed and prepared PCM schedules each deliver one EOF after node-loss/resume, and each confirms recovery for a 10 ms remaining tail. Retained identity/position, stopped I/O rejection, newer pause and final drain pass. Generated CAF fixtures and an `ipod-library` logical identity do not simulate the Music daemon or real competing apps.
- Ordinary iPhone Debug simulator build succeeds on Xcode 27.1 with `ARCHS=arm64 CODE_SIGNING_ALLOWED=NO`. The only build warning is skipped App Intents metadata extraction because there is no AppIntents dependency. Prior settings-tab changes remain intact.

[Recorded test output](measurements/track-end-followup-2026-10-20.txt)

## Physical-device status

⭕️ [Pending] Use the user's Music-managed non-DRM songs and built-in speaker to verify ordinary playback, next-song audio, repeat-one, album wrap, background/lock-screen operation, other-app takeover followed by explicit Play, near-EOF recovery, repeated interruptions and quality replacements under load. Check both selected-song/button state and audible output. Confirm a newer pause or track selection is never overridden. The intermittent user-reported hardware symptom remains unverified until this test is completed.
