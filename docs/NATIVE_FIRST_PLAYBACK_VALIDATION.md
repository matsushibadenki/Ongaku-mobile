# Native-first playback — 2026-10-16

## Behavior

🟢 [Done] Transport readiness follows the native engine, independently of background quality/effect flags. Local and readable non-DRM Music assets start through Apple's AVAudioEngine/AVAudioFile streaming path; DRM and initially unreadable Music assets start with the system Music player. Startup restoration prepares a paused system queue so play can reuse it. Full-song conversion is no longer a foreground fallback that delays controls and first sound.

🟢 [Done] Precision Sinc preparation starts at background priority after native playback starts. The existing host-clock-aligned two-node crossfade preserves the current seek position. It samples current effect settings at commit, rejects stale tracks/spatial revisions, and cannot resume an explicitly paused track.

🟢 [Done] Non-file Music assets can use a temporary AVAssetExportPresetPassthrough copy for conversion. Reject protected content, unsupported exports, cancellation, and duration changes of 50 ms or more. Limit snapshots to 512 MiB, remove them when conversion/playback releases ownership, retain the original song identity for handoff/cache lookup, and leave native playback running when optional preparation fails. This is passthrough export, not AAC re-encoding. [Apple passthrough documentation](https://developer.apple.com/documentation/avfoundation/avassetexportpresetpassthrough).

🟢 [Done] Store current-track quality data and prepare one following non-DRM queue item in the existing 1.5 GiB bounded disk cache. Do not retain next-track PCM in the engine. Serialize next-track work after current conversion, respect the live process-memory budget, and cancel optional work for selection changes, cache clearing, serious thermal pressure and memory pressure. Continue background work while the app owns active local playback; system-Music playback alone cannot guarantee execution while this app is suspended.

🟢 [Done] Recover exportable non-DRM Music assets from system playback into the effect-capable app engine. Keep Music playing while a snapshot is validated/opened and the replacement graph is started in a temporary mixable session. Sample the latest position after preparation, start the incoming node with a 12 ms fade-in, and pause Music only after the replacement render clock advances through its DSP pipeline. Preserve the latest effect selection and original cache identity. Cancel stale requests on selection/pause/interruption, skip handoff near EOF, and retain Music playback if app-engine preparation fails. Protected assets and assets that cannot be exported or decoded remain on system playback.

🟢 [Done] Keep the playback ring visible during loading and keep Basic/other UI accents orange independently of the automatic quality mode. Breathing remains limited to active playback.

## Verification

- Final application Debug simulator build succeeded.
- Transport readiness/state, asynchronous file opening/cancellation and audio-session ordering regressions passed.
- Handoff clock regressions and 216 scheduled waveform/seek comparisons passed, with deliberate misalignment rejected.
- `bash tests/run_music_asset_preparation_regression.sh` passed: actual passthrough export preserved stereo PCM sample-for-sample and duration, scoped cleanup removed only the copy, and pre-cancelled requests produced no snapshot.
- `tests/NativeFirstPlaybackAuditApp.swift` ran against the shipping engine in an isolated iOS 27 simulator app. Native streaming was ready before precision conversion (1,908–2,279 ms across simulator runs; not an iPhone latency guarantee). Playback upgraded without resetting the seek position, including conversion from a separate passthrough snapshot with the original track identity. Current/next files reached disk cache, cache reuse was confirmed, pause remained paused after completion, and stop invalidated an in-flight handoff.
- The recovery extension passed using a pre-opened passthrough file: the production effect-capable graph resumed with fade-in and then passed the existing quality/cache/pause/stop audit. This fixture does not exercise the system Music service.
- Isolated production controls rendered correctly in Light and Dark: loading, paused and playing buttons retained orange rings, and Basic retained the orange selection fill.
- Reproduce the isolated engine run on Apple Silicon with `bash tests/run_native_first_simulator_audit.sh <installed-simulator-UUID>`. Its separate bundle ID and cache do not modify the main app's library.

## Limits

⭕️ [Pending] Physical-device first-sound latency, DRM authorization, Music asset export availability, Bluetooth output and audible/energy behavior under real memory pressure. Simulator PCM fixtures do not reproduce the user's Music account or DRM tracks. A protected asset, or an asset unavailable to both export and decoding, stays on system playback. No sample-accurate crossfade from the system Music daemon into the app is claimed; quality upgrades within AVAudioEngine share its clock, whereas recovery from system Music crosses independent clocks and uses a short overlap; exact phase alignment and hardware continuity require device verification. Verify the recovered effects, position, pause/track-change races and rollback on an affected physical iPhone.

A long track may exceed the existing offline conversion memory budget. Native playback stays available and quality preparation is deferred. Remote/File Provider sources still require a complete local file before the current engine can start; the codec readiness contract has not changed.

The previously generated Release archive predates this change. Rebuild and sign the final archive before distribution.

## Intermittent non-DRM recovery — 2026-10-16

🟢 [Done] Initiate current-track preparation from confirmed Music playback observations, including delayed starts, restored/resumed playback and Music-managed queue advancement. A per-song/selection gate prevents repeated notifications from launching duplicate preparation or endlessly retrying failures. Track changes cancel obsolete work; pause/background cancellation and explicit retry re-arm it. A transient non-playing observation before handoff also re-arms preparation. Prefer the matching live Music item's asset URL, with the library item as fallback.

🟢 [Done] Validate that a passthrough result can actually be opened by AVAudioFile. If export or opening fails, read the unprotected AVAsset with AVAssetReader and write Float32 PCM to CAF in at most 8,192-frame chunks. Preserve sample rate/channels, validate timestamps and duration, reject results above 512 MiB, and remove temporary copies with their playback owner. This is decoding, without lossy re-encoding or claiming to restore source information. [Apple's track-output contract](https://developer.apple.com/documentation/avfoundation/avassetreadertrackoutput).

🟢 [Done] Cancel preparation after a 120-second deadline, expose missing-source/preparation-failure feedback, and offer an icon-only retry action in English, Japanese and Simplified Chinese. Keep system playback running throughout preparation. Only a fully opened source enters the existing position-preserving handoff; failures leave Music playing. A failed graph/session preparation retains its failed-attempt gate to prevent an automatic retry loop; provisional app audio/session resources are released without stopping Music.

Verification:
- Asset regression: exact stereo PCM preservation, unsupported export and unreadable exported-container fallback, temporary-file cleanup, cancellation, size limit and a deliberately stalled preparation deadline passed.
- Generated MP3, AAC and 96 kHz ALAC fixtures passed readable-copy and PCM fallback checks, including rate/channel/duration validation.
- Transport regression: 500 duplicate observations launch one attempt; automatic advancement, re-selection and cancellation/retry can initiate a new attempt.
- Isolated production engine: use a decoded fallback with an `ipod-library` logical identity, observe an enabled EQ on its live signal, perform a Precision Sinc upgrade without resetting the playhead, write current/next cache entries, reuse cached quality, and preserve explicit pause/stop behavior.

⭕️ [Pending] Repeat the reported intermittent non-DRM case on the user's iPhone. The isolated engine uses generated audio and does not reproduce Music's actual asset permissions, download readiness or daemon timing. Inspect `audio.asset.recovery_begin`, `recovery_ready`, `recovered`, `recovery_skipped`, `recovery_unavailable` and `recovery_rolled_back` if a track remains on Music playback. DRM remains excluded from app decoding/effects.

## Avoid pausing Music before graph startup — 2026-10-16

🟢 [Done] Remove the pause → activate session → configure graph → seek → fade-in sequence at system-to-local recovery. Activate a temporary `.mixWithOthers` session while Music continues, without changing preferred hardware rate or buffer duration. Build the replacement graph, sample Music's latest playhead, and start the incoming source with a 12 ms fade-in. Wait for its render clock to advance beyond the estimated DSP latency plus two I/O buffers (bounded to one second) before pausing Music and transferring view-model ownership. Do not stop or reschedule the already-rendering replacement at commit. Restore exclusive playback by changing only category options, without deactivation/reactivation. [Apple mixing option](https://developer.apple.com/documentation/avfaudio/avaudiosession/categoryoptions-swift.struct/mixwithothers).

🟢 [Done] Give the temporary session an owner ID. Pausing, changing tracks or cancelling recovery stops provisional app audio; queued cleanup deactivates only the matching owner and cannot affect a newer activation. Ignore provisional local end callbacks while Music still owns playback.

Verification:
- App Debug simulator build succeeded.
- Session queue tests passed: mixing leaves hardware preferences unchanged; finish restores exclusive options without activation/deactivation; stale cleanup does not deactivate newer playback.
- The isolated production-engine audit used an AVAudioPlayer as the old audible fixture. It stayed playing through graph preparation and the render barrier. The replacement's playhead continued across commit; enabled EQ, subsequent quality upgrade, disk-cache reuse, pause and stop checks passed.
- All 216 existing shared-clock waveform/seek comparisons passed, including the intentionally misaligned replacement rejection. These comparisons concern the in-engine quality crossfade, not the system Music overlap.

⭕️ [Pending] Listen to the affected non-DRM Music track on physical iPhone, including speaker/headphones/Bluetooth. The system Music daemon does not expose the same render clock or independent fade envelope as the app engine. This removes the application's intentional silent startup interval but does not establish sample-accurate alignment or absence of route-dependent artifacts between those independent players. Temporary overlap and restoration of exclusive session options need real-device confirmation.

## Preparation diagnostics — 2026-10-17

🟢 [Done] Replace ambiguous mode-based failure messages and Boolean allocation preflight with stage/reason/domain/code diagnostics. Missing/unreadable files no longer become capacity errors. The updated production-engine Simulator audit confirms failure context, continued native playback, EOF deferral and subsequent handoff/cache/pause/stop behavior. See [diagnostic verification](PREPARATION_DIAGNOSTICS_VALIDATION.md).

⭕️ [Pending] Recheck affected physical Music assets and live memory pressure using the new diagnostics; simulator source errors cannot reproduce account/service behavior.


## Speaker continuity follow-up — 2026-10-17

🟢 [Done] The current production-engine audit passes 17 checks, including default fade-in, pause/resume and seek cancellation, gain/EQ preservation through Precision Sinc replacement, pause before the incoming node starts and rapid resume during an active quality overlap. The confirmed EOF deferral/cached retry remains bounded. See [transport and gain verification](PLAYBACK_CONTINUITY_VALIDATION.md).

⭕️ [Pending] Reproduce the reported click/level symptoms on the physical iPhone built-in speaker. Simulator success does not validate its hardware/session behavior or every destructive track teardown.
