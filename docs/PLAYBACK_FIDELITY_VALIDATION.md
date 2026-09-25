# Playback fidelity validation

## Current runtime status: stock mixer restored

After stage 2, the affected iPhone reported silence, audio-session main-thread
hang-risk diagnostics, and a signal-9 termination. The exact runtime cause of
the silence/termination is not established by those logs. The most recent audio
graph change has been isolated: production playback now uses AVAudioMixerNode
again and never instantiates the experimental HandoffMixerAudioUnit. Its source
and tests are retained for further investigation. The stage-2 results below
document offline tests, not successful iPhone validation.

The stock path retains host-clock start alignment, but the volume ramp is once
again control-rate; per-sample fading must not be advertised as active.

Additional corrective changes:

- All application AVAudioSession mutations are serialized on a dedicated queue,
  not MainActor. Activation uses an async continuation, with cancellation checked
  before and after the blocking operation. This retains support for iOS 17;
  the current SDK's native async activation/deactivation APIs require iOS 27.
- Callers recheck song/pause/interruption identity after the await and before
  starting playback. Stop deactivation is enqueued immediately, in order behind
  any activation already in flight. Screen lock no longer reactivates an already
  playing session. Unchanged category/rate/buffer preferences are not rewritten.
- Session notifications are delivered asynchronously on the main queue before
  accessing the view model, so worker-thread session changes do not introduce
  background-thread UI/state mutations or synchronous notification waits.
- The spatial worker retains an explicitly read-only PCM owner. It clones before
  any sample mutation; AVAudioPCMBuffer itself is not made globally Sendable.

Regression results:

- The iOS build passed; the reported AVAudioPCMBuffer Sendable warning is gone.
- `run_stock_playback_graph_regression.sh` passed eight file-backed graphs with
  44.1/48 kHz sources, 96 kHz internal processing, 48/96 kHz output and the actual
  HighQualityEnhancementAudioEffect disabled/enabled. Both channels rendered
  finite, nonzero signals. This is offline macOS coverage, not a device test.
- `run_audio_session_queue_regression.sh` passed main-actor responsiveness during
  blocked activation, cancellation, stop/start ordering, preference deduplication
  and error recovery. It uses a fake session on macOS and does not validate iOS
  media-server behavior.

Before restoring the custom AU, require real-time device tests of initial file
playback (before any quality upgrade), scheduled handoff, route changes, screen
lock and interruptions. To verify this recovery build on the device, look for
`audio.pipeline.source_mixer=system` and check that normal playback is audible.

## Stage 1: quality-handoff scheduling (2026-09-24)

The replacement player is scheduled with `AVAudioTime(hostTime:)`. Its PCM start
frame and host start time are derived together from the original player's render
timestamp and player timeline. Scheduling no longer estimates playback progress
from `Date`. Both sources retain the existing high-rate effect graph.

The engine defers the handoff when it has no usable render clock, insufficient
remaining audio, a mismatched graph format, or insufficient scheduling lead.
Deferred scheduling keeps the original stream and its completion callback valid.
A separate attempt token prevents a cancelled replacement callback from ending
a later schedule that happens to reuse the same playback generation.

The playback-position display follows the original source until the scheduled
replacement has rendered. Pause, seek, and stop discard leftover source
schedules. A paused quality upgrade does not start the engine.

### Automated results

- iOS Debug build, generic iOS destination, code signing disabled: passed.
- `bash tests/run_playback_handoff_regression.sh`: four groups passed, including
  36 source/target-rate and seek combinations, host-time conversion, invalid
  inputs, short tails, fade progress, and a mathematical unity-gain null check.
- `bash tests/run_playback_transport_regression.sh`: four groups passed.
- `bash tests/run_library_index_regression.sh`: six groups passed.
- `bash tests/run_effect_audit.sh`: a sandboxed attempt could not instantiate an
  Audio Unit. The first unrestricted run failed at `EQ bands enabled exciter`.
  An isolated settings probe passed, and a second unrestricted full audit passed
  952 checks (300 individual cases and 60 final-chain cases), with largest final
  sample peak 0.891247. The initial EQ failure remains unexplained; a passing
  retry is not proof that the test or Audio Unit lifecycle is deterministic.
  No effect implementation or assertion was changed to make this audit pass.

### Required device checks

1. Play 44.1 and 48 kHz files and observe `audio.handoff.scheduled` followed by
   `audio.handoff.completed`, without resetting the progress indicator.
2. Pause or seek immediately after the scheduled log, including before the new
   source starts. Resume and check that only one source is audible.
3. Repeat while scrolling rapidly, with the screen locked, and across Bluetooth
   changes and audio interruptions. Confirm no unintended restart or track-end
   event from a discarded schedule.
4. Finish preparation near the end of a song. A deferred handoff must leave the
   original end-of-track/queue transition intact.

### Limits at the end of stage 1

The stage-1 tests did not establish sample-identical device output. At that stage,
the volume crossfade still updated on the control thread, so a stalled control
thread could cause a gain jump. Stage 2 below replaces that envelope.

## Stage 2: per-sample handoff envelope (2026-09-24)

`HandoffMixerAudioUnit.mm` replaces only the two-source summing node, before the
existing input gain, effects and output protection. `HandoffMixerDSP.hpp` owns
the small envelope/command mechanism and has no Apple framework dependencies.
The internal processing rate remains unchanged. The module is compiled from the
same source in standalone macOS tests; the desktop application's different
playback graph has not been modified in this stage.

- Both source gains are calculated per sample inside one render callback, with
  linear complementary gains to avoid boosting correlated source audio.
- The envelope uses the scheduled host time, with a sample-time fallback for
  offline rendering. It handles fades crossing render-block boundaries.
- The audio thread takes a bounded, lock-free atomic command snapshot. Its own
  render code does not allocate, log, call Swift/Objective-C methods or perform
  reference counting. Scratch buffers are allocated before rendering. Inspection
  of optimized arm64 code also confirmed no retain/release in the render block.
- Once the fade finishes, the old input is no longer pulled. Delaying MainActor
  cleanup cannot extend the fade or leave the old source audible. Completion is
  reported atomically; the 50 ms UI-side poll is solely for cleanup.
- Pause, seek and stop select the appropriate source and discard pending player
  schedules. New commands invalidate old completion state. Completed fades stay
  settled even if their timestamp is subsequently missing or rebased.
- The Audio Unit implementation is explicitly in the Xcode Sources phase, with
  a bridging header for the Swift engine; it does not rely on discovery of a new
  source file by an already-open Xcode window.

### Stage-2 validation

- iOS Debug build with a fresh DerivedData directory and code signing disabled:
  passed, including explicit compilation of the Objective-C++ Audio Unit.
- `bash tests/run_handoff_mixer_tests.sh`: 24 direct Audio Unit cases passed
  across 44.1/48/96 kHz, host/sample clocks, both fade directions and identical/
  opposite-phase signals, with varying block sizes and no UI gain updates.
- An actual two-player AVAudioEngine offline graph at 96 kHz passed a waveform
  comparison with a future-scheduled replacement player. The expected fade and
  phase were verified at each sample, not merely via playback-state flags.
- Boundary cases passed: mid-fade cancellation, reverse/rearm, missing clock,
  upstream silence/error, caller-owned/null output buffers, oversized buffers,
  and rendering after resource deallocation.
- `HANDOFF_SANITIZERS=1 bash tests/run_handoff_mixer_tests.sh` passed with Address
  Sanitizer and UndefinedBehavior Sanitizer enabled.
- `HandoffEnvelopeConcurrency.cpp` passed 100,000 concurrent control commands,
  including a separate `-fsanitize=thread` run with no reported data races.
- Existing handoff-clock, transport and library regression suites passed.
- Retired the old control-rate Swift fade helper; fade/unity-gain tests now
  exercise the shipping Audio Unit rather than a separate mathematical helper.

### Remaining limits

The tests do not substitute for locked-device, Bluetooth and interruption tests
on an iPhone. They also do not prove zero SRC/group-delay differences between the
file-backed and prepared paths, true-peak safety at every hardware rate, or
click-free changes to every effect parameter. Those remain separate next steps.
This work removes UI timing from the quality-handoff envelope; it does not claim
to eliminate DAC jitter, device latency or unrelated causes of audio dropouts.

API references: [AVAudioPlayerNode](https://developer.apple.com/documentation/avfaudio/avaudioplayernode),
[play(at:)](https://developer.apple.com/documentation/avfaudio/avaudioplayernode/play(at:)),
[AVAudioTime](https://developer.apple.com/documentation/avfaudio/avaudiotime).
