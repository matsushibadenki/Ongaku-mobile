# Lyrics search and embedding (2026-10-11)

Open the lyrics button (`text.quote`) on Now Playing, or Lyrics in a track's
information sheet. Search by editable title and artist, inspect the candidate,
and choose **Use these lyrics**. Valid synchronized LRC results precede plain
lyrics; within each group, duration proximity determines order. Selection is
explicit because live recordings and album versions can differ.

Selected lyrics are atomically stored under `Documents/PlayerLibrary/Lyrics`,
keyed by the library source and song ID. Opening lyrics reads that selection
first, then existing local embedded lyrics. It does not initiate a network
search. Search is a GET to [LRCLIB's documented search endpoint](https://lrclib.net/docs)
with title/artist, a User-Agent, a 20-second timeout and an 8 MB response limit.
HTTP errors remain visible and retryable. Cancellation/request identity prevents
late searches from replacing newer results. No publish endpoint is used.

The LRC parser handles repeated line timestamps, 1–3 fractional digits,
file-wide millisecond offsets (positive values advance the lyric), simultaneous
translations and blank timed gaps. The current line comes from the transport's
elapsed seconds; binary search works for forward/backward seeking and pausing.
Now Playing observes the player's existing state updates, highlights and scrolls
to the active line, and lets a line tap seek the same track. Manual scrolling
suspends automatic following until requested. Track information also permits
searching/saving lyrics for a song that is not currently playing.

## Embedding contract

Embedding is a separate, explicit action. It replaces lyric tags in writable,
regular files under the app-managed `Documents/Ongaku` directory only. Resolved
paths must remain under that directory. Music assets, provider/remote files and
unsupported formats use app-local storage.

- MP3: conventional ID3v2.3/v2.4 tags with zero tag/frame flags, or an untagged
  MPEG stream. LRC text (including timestamps) is stored in USLT, using UTF-16
  for v2.3 and UTF-8 for v2.4. Existing USLT/SYLT records are replaced; other
  supported frames remain byte-identical. This is timestamped text in USLT,
  not generation of binary SYLT events. ID3v2.2, extended headers,
  unsynchronisation, footer/experimental tags and flagged frames are refused.
- FLAC: native FLAC metadata with a valid leading STREAMINFO block. Replace
  LYRICS/SYNCEDLYRICS/UNSYNCEDLYRICS comments with one UTF-8 LYRICS comment;
  preserve the vendor, other comments, blocks and audio payload. Duplicate
  comment blocks and malformed/truncated metadata are refused.

Metadata reads are bounded at 32 MB and lyric writes at 1 MB. The writer creates
a sibling temporary file, streams audio bytes unchanged in 1 MB chunks,
synchronizes and verifies the new lyric tag, checks the original's identity,
size and modification time, then uses a coordinated atomic replacement.
Failure before replacement retains the original; no audio re-encoding occurs.
Compatibility of timestamped USLT/LYRICS text with other players varies.
M4A/ALAC writing is covered below. Additional ID3 layouts remain future work.
AVFoundation provides a read fallback for existing embedded lyrics in other local formats.

Format references: [ID3v2.3](https://id3.org/id3v2.3.0),
[ID3v2.4 frames](https://id3.org/id3v2.4.0-frames),
[FLAC format](https://xiph.org/flac/format.html).

## Verification

`bash tests/run_lyrics_regression.sh` compiles the shipping parser, client,
store, view model and tag editor. It covers Unicode, fractional/duplicate
timestamps, positive/negative offsets, blank gaps, intro/backward-seek clock
positions, invalid LRC fallback, timed-result priority, source-isolated
persistence, URL encoding, HTTP 429, invalid JSON, cancelled/replaced requests,
and selection replacing the active line state.

File fixtures verify MP3 v2.3/v2.4/new tags and FLAC new/existing comments,
byte-for-byte audio preservation, preservation of unrelated metadata, and
unchanged originals after flagged/truncated ID3 rejection. Root/symlink guards
are checked. When FFmpeg/FFprobe are installed, independently generated MP3 and
FLAC audio are embedded, decoded before/after, and required to yield identical
PCM and the same title. Those independent decoder checks passed in this run.
On this development host the coordinated writer tests require execution outside
the shell sandbox; they operate only on temporary fixtures.

A live public-title API request returned HTTP 200 with 20 records, including
7 timed records, and the documented required fields. No real lyric text is
included in this validation document or its fixtures.

The iOS and Simulator builds passed. The actual lyric/search views were rendered
with an isolated preview host, original test text and a fixed transport clock on
iPhone SE (3rd generation) and iPhone 16 Pro Max simulators. Japanese, English and
Simplified Chinese strings are included. Preview screenshots validate layout,
not real Music authorization, touch interaction or acoustic synchronization.
Physical iPhone Music/local playback, Bluetooth latency, background/resume,
provider permissions and user listening checks remain pending in ROADMAP.


## M4A / ALAC preservation (2026-10-11)

`M4ALyricsTagEditor` supports unfragmented MP4 audio containers with AAC (`mp4a`)
or Apple Lossless (`alac`) audio entries, under `.m4a` or `.alac` filenames.
Existing text/subtitle chapter tracks are preserved. Lyrics use UTF-8 text in
the iTunes `moov/udta/meta/ilst/©lyr/data` item. Existing lyric items are replaced;
all other item bytes (including cover art and unknown/freeform tags) are retained.
The editor can create missing `udta/meta/ilst` containers and handles 32-bit and
extended-size atom headers, plus `stco` / `co64` chunk tables.

Media never moves. A front-of-file `moov` is replaced with an equal-size `free`
atom and the updated movie metadata is appended. A trailing `moov` is replaced
at the tail directly, so repeated writes do not accumulate old metadata.
This can remove the front-of-file fast-start layout, but keeps the complete
`mdat` byte ranges and all chunk offsets unchanged. The first front-layout edit
increases the file size by the updated movie metadata; subsequent identical
writes are byte-identical. Audio is neither decoded nor re-encoded by the app.
The existing staged-file verification and coordinated atomic replacement apply.

Unsupported layouts are rejected before replacing the original: fragmented or
compressed movie structures, encrypted/non-AAC/non-ALAC audio sample entries,
non-audio/non-chapter tracks, duplicate movie/metadata containers, numeric-key
`mdta` metadata, top-level/movie-level alternate metadata, to-EOF media atoms,
chunks outside the original `mdat` ranges, and malformed/oversized atoms.
Metadata remains bounded at 32 MB and lyric text at 1 MB. Files with unusual
private structures require a separate compatibility assessment; the supported
contract is conventional self-contained audio/chapter media and iTunes metadata.

Run `bash tests/run_m4a_lyrics_regression.sh` (requires FFmpeg and FFprobe).
The independent Python checker generates eight real audio fixtures: AAC/ALAC ×
44.1/96 kHz × front/tail movie metadata. Each contains existing lyrics, Japanese
title, artist/album/album-artist, composer, date, genre, disc/track numbers,
comment, chapter titles, a PNG cover, ReplayGain-style freeform metadata and an
opaque custom item. All eight passed:

- Exact compressed packet SHA-256 hashes, packet timing and media positions.
- Exact decoded float64 PCM, preserving sample precision in the comparison.
- Exact bytes of every non-lyric metadata child and the original media ranges.
- FFprobe equality of stream/technical metadata, chapter data and all format tags
  except lyrics. Cover bytes/hash remain identical; their position within the
  updated metadata can change.
- Round-trip Unicode LRC in both the shipping reader and AVFoundation.
- A second identical embedding yields a byte-identical file.

Additional fixtures pass for the `.alac` extension, absent metadata, extended
atom sizes and 64-bit chunk tables. Nine corrupt/unsupported layouts are refused
with byte-identical originals. The previous MP3/FLAC/client/store regressions
also passed with the new writer integrated. The final unsigned iOS build passed.
Physical-device playback during embedding and interoperability with other players
remain pending; desktop codec and parser results do not establish every player's
interpretation of timestamped lyric text.

## Japanese lyric search sites

The search form now includes Uta-Net and UtaTen browser links. Both use the current
editable fields, with whitespace-only searches disabled and Unicode, `+`, `&`,
`#` and `?` encoded as query values. Uta-Net uses title search (artist when title
is empty); UtaTen supplies separate title/artist fields. Navigation occurs only
when the user opens a link. The app does not scrape, cache, import or embed lyric
text from these websites; LRCLIB continues to provide selectable stored LRC.
The distinction is visible in all three supported languages.

[Uta-Net's help](https://www.uta-net.com/info/help.html) describes its lyric search;
its [terms](https://www.uta-net.com/info/kiyaku.html) permit ordinary text links
and prohibit unauthorized copying/scraping. The search URL uses its title/artist
selector and keyword parameters. Direct requests from this environment returned
HTTP 403, so normal-browser search navigation is recorded as pending.
[UtaTen's public search form](https://utaten.com/) supplies `/lyric/search` with
`title` and `artist_name`; a live Japanese-title query returned HTTP 200 and
retained the query. No retrieved lyric text is stored in the test fixtures.

URL encoding/empty-query/artist-only cases pass in the regression executable.
The actual updated SwiftUI search view was rendered with the isolated preview
host on iPhone SE (3rd generation) and iPhone 16 Pro Max. Both show the two
browser links, explanatory text and search fields inside the safe area. These
screenshots verify layout, not an automated tap-through of external browsers.
