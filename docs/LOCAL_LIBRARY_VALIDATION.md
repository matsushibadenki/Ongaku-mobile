# Local library and iPad corrections — 2026-10-16

## Report and evidence

The report concerns albums copied as folders into Documents/Ongaku: missing Library artwork, split compilation albums, incorrect track order, and an upper-right offset on iPad Air (5th generation). No sample files or additional format information were available. These are source-level causes and fixture-based checks, not a reproduction using the reporter's music.

| Symptom | Cause found | Correction |
| --- | --- | --- |
| Artwork appears in Now Playing but not Library | Library thumbnails queried only MPMediaLibrary; the separate Now Playing loader read local embedded artwork | Shared local artwork reader, asynchronous thumbnails in album grids, headers, artist rows and song rows; Apple artwork lookup remains available for system songs |
| Compilations split by performer | Fallback album identity contained each song's artist | Local identity uses album folder and album title, independent of performer; album-artist tags determine display attribution, with a localized Various Artists fallback |
| Track order is incorrect | Local extraction always returned nil track/disc numbers | Read track, disc and album-artist metadata; order album lists/queues by disc, track, then natural filename order |
| iPad content shifts or overflows | Width derived from the first scene's full screen, imposed as fixed frames; app targeted iPhone only | Target iPhone and iPad, use proposed container widths with a 760 pt cap, adapt marquee text to its cell and constrain the root to its actual viewport |

## File handling

- AVFoundation reads common, ID3 and iTunes metadata. Native bounded FLAC comment/picture parsing and WAV RIFF INFO parsing fill format-specific gaps. WAV supports ITRK and IPRT track tags.
- Missing album tags use the containing folder's name. CD1/CD2, Disc 1/Disc 2 and Disk 1/Disk 2 directories share their parent album and provide a missing disc number.
- Embedded artwork is preferred. Fallback names are cover, folder, front, artwork, or the album directory name (case-insensitive), with JPG/JPEG/PNG/HEIC/WebP extensions. Disc subfolders also check the parent album directory.
- Visible Library artwork is downsampled to at most 512 px, with deduplicated in-flight reads and a 24 MiB/128-entry cache. The audio file itself is never loaded wholesale for fallback tag parsing.
- Local metadata cache version advances from 2 to 3, so the next scan repopulates previously missing numbers and album-artist tags without reimporting music.
- Local songs remain browsable in Library/Search when Apple Music permission is unavailable. No new permission is required for files already in the app's Documents directory.
- Existing Apple album persistent IDs and playlist ordering are preserved. Natural sorting is used for album contents, not user-authored playlists. Different local folders with the same album title remain distinct.

## Automated checks

🟢 [Done] `bash tests/run_local_library_regression.sh` passes ten groups of assertions using generated, real audio files. Requires Python 3, FFmpeg and the Xcode Swift compiler.

- MP3, AAC/M4A, FLAC, AIFF and WAV title/artist/album/track metadata and decodable artwork.
- Disc and album-artist tags in MP3/M4A/FLAC/AIFF.
- Embedded artwork in isolated directories with no fallback image; uppercase folder-image filenames for WAV.
- A compilation with different performers and no album-artist tag becomes one album; tracks numbered 2 and 10 appear in that order.
- Same-title albums in different folders stay separate.
- Multi-disc folders group correctly; untagged files sort numerically and use parent-folder artwork.
- Missing artwork and truncated FLAC metadata return safely.
- Local album identity survives JSON round-trip.

🟢 [Done] `bash tests/run_library_index_regression.sh` passes all eight existing groups, including Apple IDs, compilation performers, legacy cached songs and navigation/search consistency.

🟢 [Done] Debug iOS Simulator build succeeds for scheme `audio`. Built Info.plist contains both UIDeviceFamily 1 and 2. `git diff --check` passes.

## Visual validation and limits

The temporary project `/private/tmp/OngakuLibraryAudit` uses production scanning, indexing, artwork and SwiftUI views, plus generated music in Documents/Ongaku. Launch options select albums, an album detail or Now Playing and request landscape. The later visual host disables system-service registration and sets its model's Music access state to denied, avoiding Music account dependencies; desktop sync and update checking are also excluded. These hooks are absent from shipping sources.

An attempted simulator Music-permission grant was rejected by automatic approval review because explicit authorization for that permission change was absent. No grant was performed. Old permission dialogs remained over simulator windows until restart; screenshots taken with those dialogs are not clean visual evidence.

🟢 [Done] After simulator restart, clean album-detail captures on iPad Air 11-inch (M3), iPhone SE (3rd generation) and iPhone 16 Pro Max, using iOS 26.2, show both performers in the same album and tracks 2 then 10. Titles, rows and the bottom menu stay within the portrait viewport. The iPad Now Playing placeholder screen also stays centered and contained. Captures are under `/private/tmp/OngakuLibraryAudit-*`.

🟢 [Done] Final clean album-grid captures on iPad and SE show both the embedded-artwork Collection album and the parent-folder-artwork Untagged album, using an orange fixture image. Empty and Mix deliberately have no image and display the placeholder. No rightward offset or horizontal overflow is visible; SE uses the existing scroll view for lower rows.

⭕️ [Pending] Landscape rotation was requested by the visual host, but the simulator remained portrait; do not treat that capture as landscape verification. Confirm rotation, Split View/Stage Manager resizing, the reporter's original music on iPhone 12 and iPad Air (5th generation), the reported OS version, audio playback, and actual Music permission transitions. Simulator-generated fixtures cannot establish compatibility with every possible metadata variant or image encoding.
