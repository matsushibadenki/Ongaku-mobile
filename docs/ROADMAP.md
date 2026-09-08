# #Ongaku Roadmap

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
