# #Ongaku Roadmap

## Remote music sources

- [Next] Define a source-neutral remote playback layer shared by iPhone and Ongaku desktop. Separate browsing and metadata from byte-range reads, local buffering, cancellation, retry, and playback state so that Google Drive and NAS support do not enter the audio engine as provider-specific code.
- [Next] Add Google Drive playback using an app-owned iOS OAuth client, Google Sign-In, and the narrowest viable Drive permission. Let the user select audio files, retain only identifiers and metadata, and stream with HTTP byte-range reads into a bounded on-device cache. Resume expired access tokens without interrupting playback and never store a client secret in the app.
- [Next] Add NAS playback through the iOS Files document/folder picker first. Support security-scoped bookmarks and coordinated access to SMB locations that the user has already connected in Files, with clear handling when the provider must materialize a remote file locally.
- [Later] Add direct SMB2/SMB3 connection for NAS devices when Files integration is insufficient. Store credentials in Keychain, require encrypted/authenticated sessions where supported, implement bounded read-ahead and seek caching, and isolate the SMB client behind the same remote-source interface.
- [Later] Coordinate remote source definitions, playlists, metadata, and cache hints with Ongaku desktop without synchronizing OAuth tokens or NAS passwords between devices. Each device authenticates independently.
- [Later] Add resilience and audio tests for slow networks, loss of connectivity, token expiry, NAS sleep/wake, seeking, track transitions, cache eviction, memory pressure, backgrounding, and interruption recovery.

### Product and review constraints

- Google OAuth client IDs identify an application and are not secrets. The distributed app should normally contain #Ongaku's registered iOS client ID; users should sign in to their Google account rather than enter their own client ID.
- Whole-Drive read access uses a restricted Google Drive scope and can require OAuth verification. Prefer a user-selection flow and `drive.file` where it meets the library experience; otherwise plan verification before release.
- Remote playback must use a disk-backed size-limited cache rather than retaining complete tracks in memory. The audio engine should only receive a stable local/range-backed source after enough data is buffered.
