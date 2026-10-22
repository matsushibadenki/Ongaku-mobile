# Foreground track-end follow-up — 2026-10-21

The user reports that mobile still sometimes remains on the finished song, including while active. This invalidates any assumption that the failure requires background suspension. The affected device's latest playback path/log has not been captured; the exact reported occurrence is **not** reproduced or declared resolved.

## Confirmed gaps and changes

1. The 250 ms transport/EOF timer was registered only in the default run-loop mode. Register it in common modes so UI tracking does not suspend this fallback. Desktop already uses common modes.
2. The local watchdog checked player/engine flags and output render callbacks. A source clock that stopped advancing while those remained healthy had no recovery path. `PlaybackProgressWatchdog` now observes source position per schedule. Two seconds of continuous polling without at least 5 ms of position change requests the existing bounded, intent-checked recovery. A polling gap over one second, changed schedule, seek, invalid value or inactive intent resets the observation. It does not infer EOF from elapsed wall time or sound level, and does not skip a silent track.
3. A natural EOF arriving during unexpected-stop recovery's delay or session activation could be discarded by the subsequent seek. Check accepted EOF after both suspension points and release recovery ownership before the existing queue handler. Do not reactivate/replay a completed source when its EOF is already known.

Existing pause/stop/selection generation guards, per-schedule completion deduplication, CPU upsampling, effects and audio format are retained. Diagnostic reasons include `source_progress_stalled` and `audio.local.recovery_completed_by_eof`.

## Verification

- `bash tests/run_track_progress_regression.sh`: five PASS groups. Exercises the production timer in a real AppKit tracking run loop, production tick and queue handler with controlled engine state, one recovery for a frozen clock/healthy graph, missing-callback next/repeat-one/album-wrap/final-stop, active-source/pause/interruption/startup/recovery guards and observation resets. Both negative controls fail as intended when the old default-mode timer or missing source-progress check is restored. OS/audio collaborators in this test are substitutes; it is not an iPhone media-daemon reproduction.
- `bash tests/run_foreground_recovery_regression.sh`: 14 PASS groups and three negative controls. Includes accepted EOF during recovery delay and activation, with **zero seeks/progress retries**. Restoring the old seek-over-EOF behavior fails the new check. Existing interruption, stale intent and short-tail checks pass.
- `bash tests/run_recovered_track_end_regression.sh`: ten queue/intent cases and the stranded-seek negative control pass.
- `bash tests/run_prepared_eof_regression.sh`: three schedule groups and the old global-token negative control pass.
- Ordinary `xcodebuild -project Ongaku.xcodeproj -scheme audio -configuration Debug -destination 'generic/platform=iOS Simulator' ... CODE_SIGNING_ALLOWED=NO build`: succeeds for arm64/x86_64. Only the existing AppIntents metadata-extraction notice is reported.
- `bash tests/run_native_first_simulator_audit.sh 8220EDC1-4303-49BF-B480-0484AC2BBB47 --track-progress`: isolated iPhone SE (3rd generation) Simulator app uses the actual `AudioPlayerViewModel` and `HiResPlaybackEngine` with generated three-second local files. Removes engine-to-ViewModel completion delivery, then verifies timer-driven next song, final stop, single-track repeat and album wrap. Repeat validation observes a position beyond the middle of the song before checking the restart, to avoid confusing a quality handoff with repetition. This exercises real rendering and queue control; the frozen-clock case above remains fault-injected.
- `git diff --check`: passes. No UI/localization strings changed in this follow-up.

Logs: `/private/tmp/ongaku-track-progress-2026-10-21.log`, `/private/tmp/ongaku-foreground-eof-2026-10-21.log`, `/private/tmp/ongaku-recovered-eof-2026-10-21.log`, `/private/tmp/ongaku-prepared-eof-2026-10-21.log`, `/private/tmp/ongaku-track-progress-build-2026-10-21.log`, `/private/tmp/ongaku-track-progress-simulator-2026-10-21.log`.

## Device qualification

⭕️ [Pending] Reproduce/verify the reported Music-managed non-DRM CD tracks on the physical iPhone speaker: foreground idle and scrolling, other-app takeover/manual resume, high-quality handoff near EOF, next/repeat-one/album wrap, long playback and background. Identify local versus Music system playback and capture the EOF/recovery reason if it stops again. Music/system-player timing and real audio-session arbitration are not represented by generated-file Simulator tests. The present changes target local transport and its timer; they do not establish a fix for a separate system-player failure.

Desktop inspection confirms its common-mode timer and schedule-scoped EOF ownership. Desktop runtime is unchanged in this follow-up; neither Desktop frozen-clock recovery nor hardware parity is claimed tested here.
