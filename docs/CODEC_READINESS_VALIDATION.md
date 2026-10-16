# Codec readiness and complete-file playback — 2026-10-16

## Decision

All currently supported formats require a **complete, immutable local file** before entering the AVAudioFile/effect engine. Accepting a prefix is insufficient: the graph uses declared length, random seeks, analysis, precision-sinc preparation and next-source handoffs. AVAudioFile offers file reading and frame-position seeking, not a network-buffer replenishment contract; see [Apple's AVAudioFile documentation](https://developer.apple.com/documentation/avfaudio/avaudiofile).

Do not enable early playback for any extension based only on successful `AVAudioFile` construction. A future progressive decoder needs an explicit available-frame/EOF distinction, seek/range coordination, cancellation and growth-aware duration, and compatibility with the existing effects and preparation pipeline.

## Experiment

`bash tests/run_codec_readiness_probe.sh /private/tmp/codecs.json` requires Swift, Python 3 and FFmpeg. Generate two seconds of distinct 997/12001 Hz stereo content, and test each full file plus 10%/50%/90% byte prefixes. Each probe runs in a separate process with a 30-second timeout. Decode sequentially into bounded 4096-frame PCM buffers, verify finite PCM, then seek to 10%/50%/90% of the file's declared frame length and request 1024 frames. Errors retain the stage and frames decoded before failure, so “opened” is not mistaken for a completed probe.

All eleven complete-file variants decoded more than 80,000 frames and supported the three seeks. The AAC ADTS fixture decodes 90,112 frames; other complete fixtures decode 88,200. Compression padding is not classified as progressive support.

| Variant | Observed prefix behavior at 50% bytes | Current policy |
| --- | --- | --- |
| MP3 | Opens; decodes 43,200 frames, then decode error | Complete file |
| AAC/M4A, fast-start AAC/M4A | Open failure | Complete file |
| FLAC | Opens; decodes 41,472 frames, then decode error | Complete file |
| WAV | Finishes at shortened 44,090-frame length; seeks only within prefix | Complete file |
| AIF / AIFF | Opens; decodes 44,093 frames, then decode error | Complete file |
| PCM CAF | Opens; decodes 44,091 frames, then decode error | Complete file |
| AAC ADTS | Finishes at shortened 44,032-frame length; seeks only within prefix | Complete file |
| ALAC in `.alac` / `.m4a` | Open failure | Complete file |

These are macOS decoder observations, not a claim that every iOS version or metadata layout behaves identically. Both shortened EOF and failure prevent a safe handoff to the current engine. [All 44 observations](measurements/codec-readiness-2026-10-16.json).

## Implemented playback boundary

- RemoteAudioReadiness checks regular-file status, nonzero size and, for remote publication, exact expected byte count. Clear cached URL resource values before checking files that were just written.
- StreamingAudioFilePreparation rejects `.partial` and `.range-partial` paths before invoking AVAudioFile. The decoder never receives the cache's staging files.
- File Provider copies verify final byte count before rename. Range transfers reject empty, short and oversized responses before writing or advancing resume metadata. Expected identity/revision/length are pinned to the descriptor used by the cache caller.
- Publish only after synchronize/close, final size validation and cancellation check. Unfinished transfers retain resumable staging data; complete paths are atomically renamed.
- Serialize staging writers across actor re-entry during network awaits. Concurrent requests for the same completed resource reuse it. Invalid/unrecorded resume counts restart conservatively; verified completed chunks survive interruption.

`bash tests/run_remote_readiness_regression.sh` verifies response lengths, no premature publication, interrupted exact-byte resume, concurrent requests, staging rejection and size mismatch. `bash tests/run_streaming_file_preparation_regression.sh` verifies PCM preservation, staging rejection before decoder I/O, UI-thread responsiveness, cancellation and error delivery.

🟢 [Done] Complete the format assessment and enforce the complete-file boundary. No partially downloaded format is enabled for the current engine.

🔴 [Later] A provider-backed progressive decoder with a separate buffered-PCM contract, if faster-than-complete-file startup is required.

⭕️ [Pending] Repeat with physical iPhone File Providers/NAS, slow networks, actual Google Drive revisions and large files. The fixture tests do not validate remote server or OS-provider behavior.
