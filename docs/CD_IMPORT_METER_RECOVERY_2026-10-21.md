# CD-import playback / meter recovery — 2026-10-21

## Investigation

The reported CD-imported songs have neither working meters nor available effects. Both features require the local AVAudioEngine path; Music/system playback cannot supply this app's PCM samples. This is consistent with a source-routing problem, rather than needle drawing alone. The affected iPhone asset and its logs are not available locally, so the precise source error remains unconfirmed.

A concrete gap exists in initial playback: a tagged `streaming_open` error sent a non-DRM Music item directly to system playback. The existing snapshot/export/PCM compatibility path was only attempted after Music became audibly active, where it depended on OS asset availability and mixed-session recovery. A readable AVAsset could therefore remain on the system path even when a local compatibility copy was possible.

## Implemented

- 🟢 [Done] Attempt the normal immediate local load first. Only an unprotected source-open preparation failure triggers one compatibility snapshot and one local reload before system fallback. Session/graph/start/capacity errors and cancellation are not treated as file-format failures. A successful direct load does not export or delay on full-song copying.
- 🟢 [Done] Reuse the existing lossless passthrough / chunked float-PCM compatibility implementation, including protection checks, original sample rate/channel count, size limits, timeout, cancellation and temporary-file cleanup. Retain the successful snapshot through playback and Precision Sinc preparation; use its readable URL consistently for the quality upgrade.
- 🟢 [Done] Recheck cancellation, selection generation, song ID and local-source ownership before both initial and retry graph loads and before committing the snapshot. Preserve existing system fallback if compatibility preparation also fails.
- 🟢 [Done] Record `audio.asset.local_open_failed` with the original stage/reason, `audio.asset.local_snapshot_retry` and `audio.asset.local_snapshot_ready`. Snapshot failures retain `asset_snapshot` diagnostics. No source paths are logged.
- 🟢 [Done] Correct EN/JA/zh-Hans format labels: an unprotected system fallback now says System playback, rather than Protected system playback. DSP algorithms, VU calibration/geometry and the previous 60 Hz display policy are unchanged. Mac runtime is unchanged.

## Validation

- 🟢 [Done] `bash tests/run_music_asset_preparation_regression.sh`: force the same source-open failure branch, then verify successful local retry, exact PCM and snapshot lifetime. Generate CD-quality 44.1 kHz / 16-bit WAV, AIFF and ALAC in mono and stereo (six conditions), checking every decoded sample, frame count, sample rate and channel count after recovery. These are injected source-open errors on real test assets, not a reproduction of the user's exact iPhone Music asset failure.
- 🟢 [Done] Confirm readable sources bypass export, protected/session failures do not export, cancellation after snapshot preparation prevents a second graph load, and existing passthrough/PCM fallback, timeout, capacity and cleanup tests pass.
- 🟢 [Done] Prepared-EOF regressions (including negative control), foreground recovery regressions (including both negative controls), ordinary arm64/x86_64 iOS Simulator Debug app build, all three locale syntax checks and whitespace checks pass.
- Local logs: `/private/tmp/ongaku-cd-asset-regression.log`, `/private/tmp/ongaku-cd-meter-build.log`, `/private/tmp/ongaku-cd-prepared-eof.log`, `/private/tmp/ongaku-cd-foreground-recovery.log`.

## Pending

- ⭕️ [Pending] On the affected iPhone, replay the reported CD songs and confirm both actual RMS/spectrum movement and audible effect changes. Collect the route/open/snapshot diagnostics if either remains unavailable. Test initial play, next/repeat, pause during preparation, foreground recovery and Precision Sinc upgrade.
- ⭕️ [Pending] Music-managed assets with no accessible assetURL, cloud-only items, provider restrictions, OS-dependent codec exposure and compatibility copies exceeding the existing budget cannot be qualified using generated local fixtures. Do not infer DRM merely from CD provenance or from a failed open, and do not fake meter movement on system playback.
