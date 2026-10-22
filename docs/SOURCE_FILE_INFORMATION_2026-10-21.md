# Source-file information in track details — 2026-10-21

- 🟢 [Done] Add original-file metadata to mobile TrackCapabilityDetailView and desktop TrackInspector: file extension, actual codec ID, sample rate, reported source bit depth, channel count, estimated bitrate, measured file size, protection status and metadata-access result/error domain/code. Mobile also shows whether Music exposes a source URL. Desktop shows the active DSP rate/channel count separately when the inspected track is playing.
- 🟢 [Done] Use the same byte-identical AudioSourceFileInfo implementation in both apps. Load AVAsset metadata off MainActor; cancel discarded requests and reject stale UI results when selection/URL changes. Do not start playback, export a compatibility copy or materialize the remote cache to inspect a file. No guessed decoding precision or 96 kHz processing values are presented as source metadata. Unknown or unavailable fields stay explicitly Unknown.
- 🟢 [Done] Keep extension and codec distinct; OS refusal of a misleading extension must not invent a codec. For PCM, calculate payload bitrate from the original stream's sample rate/bytes-per-frame only when the asset does not report it. Compression format bit depth is shown only when the original stream reports it. Metadata success and URL presence are not guarantees of successful audio decoding or app-owned playback.
- 🟢 [Done] Add EN/JA/zh-Hans labels. Use existing scrollable detail containers, selectable values and wrapping error text. Add both required mobile previews.

## Validation

- 🟢 [Done] `bash tests/run_audio_source_info_regression.sh`: generate WAV/AIFF/AAC/ALAC × mono/stereo (8 conditions), confirm 44.1 kHz, original channel counts, PCM 16-bit and payload bitrate, codec identity, compressed depth never inferred as Float32, size/protection, missing URL/file and misleading-extension behavior.
- 🟢 [Done] Ordinary mobile arm64/x86_64 Simulator Debug build, desktop Debug build and desktop App Store Release build pass. All six locale files and whitespace checks pass. Shared source files match byte-for-byte.
- 🟢 [Done] Render the actual mobile detail screen on iPhone SE (3rd generation) and iPhone 16 Pro Max Simulators, including a readable mono WAV and missing-file error. Inspect Japanese wrapping, values and insets. Screenshots: [SE details](measurements/source-info-2026-10-21/se-details.png), [SE unavailable](measurements/source-info-2026-10-21/se-unavailable.png), [Pro Max](measurements/source-info-2026-10-21/pro-max-details.png). Test entry point: `tests/SourceInfoAuditApp.swift` (isolated audit bundle, no production data).
- Local logs: `/private/tmp/ongaku-sourceinfo-regression.log`, `/private/tmp/ongaku-sourceinfo-mobile-build.log`, `/private/tmp/ongaku-sourceinfo-desktop-build.log`, `/private/tmp/ongaku-sourceinfo-store-build.log`.

## Pending

- ⭕️ [Pending] Confirm actual Music-managed CD tracks, downloaded/cloud-only/protected items, missing/provider-restricted URLs and relinked files on the user's iPhone/Mac. Metadata visibility depends on the OS/provider and is separate from the playback decoder/snapshot recovery. Check on physical devices and with large accessibility text. Playback/reading outcomes for the user's original songs remain Pending in the CD recovery records.
