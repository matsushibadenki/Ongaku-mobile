# #Ongaku Roadmap

## Playback fidelity and timing

- [Done] After the iPhone silent-playback report, remove the experimental custom mixer from the runtime graph and restore AVAudioMixerNode. Keep audio-clock handoff scheduling, with a temporary control-rate gain ramp. The custom AU source and offline tests remain for investigation, not as the production playback path.
- [Done] Serialize audio-session activation/deactivation and preference changes on a dedicated background queue; revalidate transport intent after awaiting activation, avoid reactivation on screen lock, and explicitly register the new session source in the build target.
- [Done] Use a narrowly scoped read-only PCM owner for spatial-processing work instead of capturing a non-Sendable AVAudioPCMBuffer directly. Keep all mutations on a separate cloned buffer.
- [Done] Add queue-order/cancellation/error regression tests and stock-mixer file-backed rendering tests with enhancement off/on (`run_audio_session_queue_regression.sh`, `run_stock_playback_graph_regression.sh`).
- [Next] Confirm sound restoration, pause during activation, screen-lock playback and interruption recovery on the affected iPhone. The supplied signal-9 log alone does not identify jetsam, watchdog termination or a debugger stop.
- [Done] Keep the existing 96 kHz internal effect graph during quality upgrades; schedule the replacement from the old player's render/host clock, align its start to a prepared PCM frame, and defer unsafe or late handoffs without stopping the original stream.
- [Done] Derive handoff progress from rendered frames, preserve the original playback position until the replacement renders, and clear both source schedules on pause/seek/stop. Use exact scheduled frame positions after file-backed seeks.
- [Done] Add rate/seek/host-clock, invalid-clock and track-tail regression checks (`bash tests/run_playback_handoff_regression.sh`). Fade and correlated-signal gain checks now exercise the real Audio Unit in `run_handoff_mixer_tests.sh`; neither suite measures physical hardware.
- [Done] Record automated results, remaining limitations and the device checklist in [Playback fidelity validation](PLAYBACK_FIDELITY_VALIDATION.md).
- [Next] Investigate the existing macOS effect audit's intermittent `EQ bands enabled exciter` failure; an isolated probe and a full retry passed, but the initial failure remains unexplained.
- [Later] Re-enable the experimental per-sample C++ handoff mixer only after real-time iPhone validation and investigation of the silent-playback regression. The offline implementation passed tests but is currently disabled in the application graph.
- [Done] Add offline Audio Unit/AVAudioEngine waveform tests for 44.1/48/96 kHz, scheduled starts, variable block sizes, cancellation, reverse fades, buffer limits and silent/error inputs. Verify memory safety with Address/UndefinedBehavior Sanitizers and the bounded command snapshot with Thread Sanitizer (`bash tests/run_handoff_mixer_tests.sh`).
- [Next] Measure source-path SRC/group-delay differences and final output conversion using impulses, sines and null comparisons; verify 44.1/48 kHz devices while retaining high-rate effect processing. Coordinate the measurement contract with Ongaku desktop's separate signal-path implementation.
- [Next] On an iPhone, verify normal-to-HQ handoff under UI load, pause/resume/seek during the handoff, route changes, interruptions, near-end preparation and locked-device playback. Check `audio.handoff.scheduled/completed/deferred` diagnostics.
- [Later] Validate final true-peak headroom and smooth effect parameter/bypass transitions with end-to-end rendered-waveform tests. Application scheduling cannot eliminate DAC clock jitter or device/Bluetooth latency.

## Playback state and interruption recovery

- [Done] Stop publishing app-owned Now Playing metadata during Music playback, throttle unchanged local progress publications, invalidate stale reinforcement tasks, and cancel queued Music-session release after a new selection. Add regression coverage and transport-origin/early-playback diagnostics.
- [Next] Reproduce the reported two-second stop on the affected iPhone for both DRM and local playback. The supplied log confirms local routing but does not identify a pause command, interruption, engine stop, or render stall; inspect `audio.transport.*` in the updated build before attributing the symptom to a single cause.
- [Done] Route protected media to Music even when it has an asset URL. Prepare the selected item asynchronously, avoid rebuilding the queue on startup retries, recognize matching store IDs, and end startup loading on confirmation, preparation failure or a bounded timeout. Release the app audio session before system playback and do not cancel Music startup for app-session interruptions.
- [Done] Fetch the remaining system queue with one library query instead of repeated per-song queries, preserve Music-managed background continuation, and stop native queue construction at imported files so they are not skipped.
- [Next] Validate DRM startup and DRM/local transitions on the affected iPhone, including background queue advancement and Music interruptions. Check `audio.asset.route` and `[SystemPlayer][prepare_begin/prepare_ready/play_issued/start_confirmed/start_timeout]`; the previous policy-only tests did not establish device correctness.
- [Done] Ignore stale system-player observations during track selection, cancel protected-track starters before switching sources, and clear loading on confirmed playback of the selected DRM track. Preserve the selected item when building mixed local/system queues; add transport policy regression coverage.
- [Next] On an iPhone, verify DRM → non-DRM → DRM selection, rapid changes during protected-track startup, and mixed queues. Automated policy tests cannot exercise Apple's protected-media playback service.
- [Done] Share app/remote transport commands and derive app and Now Playing state from the running engine/player, with consistent interruption and explicit-pause handling.
- [Done] Restrict the pause watchdog to explicit pauses, invalidate asynchronous play requests on pause/track change/interruption, and add finite background execution for activation/recovery retries.
- [Done] Preserve pending interruption intent after transient activation failures and retry on subsequent route/foreground/interruption events; keep visualization timers stopped in the background.
- [Done] Add transport policy regression checks (`bash tests/run_playback_transport_regression.sh`).
- [Next] Verify locked-device interruption recovery with calls and other audio apps, including delayed session release, Bluetooth route changes, and pause/track changes during recovery. iOS controls background execution and delivery of interruption notifications.

## Music library integrity

- [Done] Give each Settings library action persistent inline feedback: source explanation, running indicator, completion count and success haptic, plus permission, playback, busy, and interruption messages in English, Japanese, and Simplified Chinese.
- [Done] Remove high-bit source detection for Apple artist/album IDs. Rebuild navigation from the retained songs during loading, cache restoration, and local-library merging.
- [Done] Keep performing-artist IDs separate from album-artist metadata, preserve compilation performers, and recover legacy cached indexes with missing artists or albums.
- [Done] Add standalone regression coverage for full-width Apple IDs, damaged cached indexes, compilation performers, mixed local/system libraries, missing IDs, and legacy JSON compatibility (`bash tests/run_library_index_regression.sh`).
- [Next] Verify the previously missing artists against the affected iPhone's Music library after installing the corrected build.

## Remote music sources

- [Done] Add the provider-independent local materialization boundary and a 1.5 GB bounded, disk-backed LRU cache. File Provider tracks are copied in cancellable 1 MB chunks and atomically published before the audio engine opens them; cache clearing and statistics include both remote and prepared-audio caches.
- [Done] Prefetch the next remote queue item into the bounded disk cache after playback stabilizes. Cancel prefetch on selection changes and keep decoded full-track PCM preloading disabled.
- [Done] Add a provider-neutral byte-range source contract, validated HTTP 206 adapter, resumable 4 MB chunk downloads, revision-aware partial metadata, cancellation, and atomic completion. This is the transport foundation for Google Drive and direct SMB adapters.
- [Next] Determine whether each codec can safely begin through the current AVAudioFile/effect pipeline before completion. Keep full materialization for formats that require arbitrary seeking; do not expose incomplete files to AVAudioFile.
- [Done] Add the OAuth-independent Google Drive media client: paginated file listing, supported-audio filtering, revision metadata, authenticated byte-range reads, strict response-length validation, and one forced token-refresh retry after HTTP 401.
- [Done] Connect Google Drive using #Ongaku's registered iOS OAuth client with the system authentication session and PKCE. Store the refresh token in this-device-only Keychain storage, refresh access tokens automatically, expose connect/refresh/disconnect controls, merge supported Drive audio into the library, and route playback and next-track prefetch through the bounded disk cache. No client secret is embedded in the app.
- [Next] Validate the Google OAuth consent screen, test-user/review configuration, sign-in callback, pagination, token refresh, background playback, and large-file range downloads on a physical iPhone. Add account identity display after validating the production consent configuration.
- [Done] Add NAS playback through the iOS Files document/folder picker. Registered folders use persistent security-scoped bookmarks, keep access alive for playback, appear in the existing music library, and can be removed from Settings. SMB servers are connected in Files and accessed through their File Provider.
- [Next] Verify NAS playback on a physical iPhone against SMB2/SMB3 servers, including provider materialization, offline errors, seeking, background playback, and large FLAC/ALAC files.
- [Later] Add direct SMB2/SMB3 connection for NAS devices when Files integration is insufficient. Store credentials in Keychain, require encrypted/authenticated sessions where supported, implement bounded read-ahead and seek caching, and isolate the SMB client behind the same remote-source interface.
- [Later] Coordinate remote source definitions, playlists, metadata, and cache hints with Ongaku desktop without synchronizing OAuth tokens or NAS passwords between devices. Each device authenticates independently.
- [Later] Add resilience and audio tests for slow networks, loss of connectivity, token expiry, NAS sleep/wake, seeking, track transitions, cache eviction, memory pressure, backgrounding, and interruption recovery.

### Product and review constraints

- Google OAuth client IDs identify an application and are not secrets. The distributed app should normally contain #Ongaku's registered iOS client ID; users should sign in to their Google account rather than enter their own client ID.
- Whole-Drive read access uses a restricted Google Drive scope and can require OAuth verification. Prefer a user-selection flow and `drive.file` where it meets the library experience; otherwise plan verification before release.
- Remote playback must use a disk-backed size-limited cache rather than retaining complete tracks in memory. The audio engine should only receive a stable local/range-backed source after enough data is buffered.
