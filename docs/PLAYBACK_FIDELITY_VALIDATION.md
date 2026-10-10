## Gain, loudness and fade-restoration transitions (2026-10-11)

Run `bash tests/run_dsp_transition_regression.sh --gain-path`. All 72 stereo
cases passed (144 channel measurements). The existing 36 transition cases also
passed again, and the unsigned generic iOS Debug build succeeded. Deliberately
bypassing the mute gate, duplicating gain planning, or recalculating gain on a
disabled-only edit each fails the corresponding regression guard.

This mode extracts the shipping source-level/automatic-DSP analysis, loudness
estimator, gain-planning law, input/output trims, audit-boost smoothing and
loudness EQ coefficients. It renders the actual Basic/Pro effect chains,
limiter and post-limiter ceiling in a 96 kHz graph at 44.1/48/96 kHz output.
Effect-audit snapshots are controlled inputs; the fixture does not reproduce
asynchronous audio-tap delivery. Main-queue deadlines use an ordered virtual
clock. The shipping loudness estimator is a gated mean-square estimate, not a
certified BS.1770/K-weighted loudness measurement.

The stereo source combines 137/997/3901/8033 Hz tones at amplitudes 0.012 or 0.20
per tone, with the right channel equal to negative one-half of the left.
Initial changes arrive at 200 ms and commit after the 20 ms fade-out. Requests
at 360/365 ms arrive during restoration, coalesce to the latest target and
commit at the next mute point. A parameter case starts at output volume 0.4
and must restore that original value. Other cases cover automatic strength and
voicing, joint effect/DSP changes, loudness volume/route changes, valid/invalid
audit snapshots, and edits confined to disabled effects.

The production fixes now:

- Plan gain once when effect and automatic-DSP/loudness changes share a commit.
- Preserve gain during disabled-only parameter edits, while retaining the latest
  parameter values for future enablement.
- Queue loudness volume/route targets through the same protected commit and
  reject nonfinite system-volume inputs. Stopping clears pending work and
  reapplies the latest contour to the stopped graph.

| Scenario | Maximum mixed sample peak | Minimum settled channel RMS |
| --- | ---: | ---: |
| Parameters during restoration | 0.151612 | 0.006064 |
| Automatic DSP during restoration | 0.363250 | 0.005086 |
| Combined effects / automatic DSP | 0.392600 | 0.015660 |
| Loudness volume / route | 0.350253 | 0.004909 |
| Controlled audit snapshots | 0.379029 | 0.015159 |
| Disabled-only parameters | 0.350253 | 0.004906 |

All live audible parameter/EQ/gain writes occur at output gain <=1e-6. Cases
with audible updates require exactly two gain commits; disabled-only edits
require zero gain commits and no mute. Guards also require finite/nonzero
output, sample peak <=0.895, settled RMS >0.00001, input trim within -12/+6 dB,
audit-boost smoothing within 0/12 dB, and the correct 1 dB post-limiter margin.
Observed input trims ranged from -5.0618 to +6 dB. These are sample-peak and
state-transition bounds for the specified signals, not true-peak or audibility
guarantees.

Loudness updates now share the intentional 20 ms fade-out / 90 ms settle /
120 ms restoration used for effect and automatic-DSP changes. Continuous
system-volume or slider changes can prolong this dip. Physical route changes,
iPhone main-thread timing, asynchronous meter convergence and listening checks
remain pending; spatial transitions are the next offline measurement target.

## Effect-setting and automatic-DSP transition protection (2026-10-11)

Run `bash tests/run_dsp_transition_regression.sh`. All 36 stereo cases passed
(72 channel measurements), including a negative control that deliberately skips
the effect mute gate and must fail. The unsigned generic iOS Debug build passed.

The engine previously protected only the first all-off -> effect-on change.
Parameters on an already-enabled effect, OFF and omitted-module changes could
write directly into the live graph. Automatic DSP also wrote four shared EQ
bands immediately, including when a replacement source was only scheduled for
future playback. Stopping during the effect mute could retain a muted output.

The shipping changes now:

- Route audible effect changes, including parameters and OFF/omitted modules,
  through the existing output de-click envelope. Edits to disabled-only effects
  do not initiate an additional mute.
- Coalesce automatic DSP strength/voicing/profile updates with queued effect
  settings, committing the latest target at the muted parameter-write point.
  Reject nonfinite strength values.
- Defer shared automatic EQ changes until the source handoff ends. Gain staging
  reads the actually applied scaled EQ profile, rather than a future queued target.
- Invalidate effect callbacks, discard pending settings/profile changes and restore
  output volume on stop, before requesting neutral EQ. The fixture also checks
  this stop/reset ordering directly in shipping source.

The suite extracts the actual configuration, effect-application, automatic-EQ,
coalescing, cancellation and gain-envelope methods from the engine. It uses the
shipping Basic/Pro registry pipelines and sample-peak limiter/post-limiter ceiling.
Only the transport shell and main-queue clock are substituted. Timer callbacks
execute in deadline/order sequence at offline render boundaries. Adaptive-gain
analysis/audit calculations are not copied in this default 36-case mode: their invocation is instrumented,
so this fixture checks that setting-driven gain staging is requested at the mute
point, but does not verify the complete normalization/trim waveform.

Cases cover Basic/Pro settings at 44.1/48/96 kHz final output with a 96 kHz
processing graph and stereo 137/997/3901/8033 Hz mixtures. Parameters are probed
at normalized 0.25 and 0.75 values, with flutter disabled. Six scenarios are
parameter changes with 5/10 ms superseding requests; OFF via an empty settings
list; automatic strength/voicing updates; a deferred automatic profile during a
modeled source-handoff interval; cancellation of an effect change; and
cancellation of a pending DSP profile followed by restarting the player.
All live setting/EQ/gain-stage-invocation writes observed by the fixture occur
at output gain <=1e-6. The final output gain returns to unity, cancelled callbacks
do not revive settings, and settled audio remains finite/nonzero.

| Scenario | Maximum mixed sample peak | Maximum adjacent-sample step |
| --- | ---: | ---: |
| Parameters | 0.224038 | 0.089382 |
| OFF / omitted modules | 0.042780 | 0.019026 |
| Automatic DSP strength/voicing | 0.039574 | 0.016501 |
| Automatic DSP after handoff | 0.041962 | 0.017685 |
| Cancel effect change | 0.039179 | 0.016305 |
| Cancel pending DSP / restart | 0.039252 | 0.016252 |

Finite output, sample peak <=0.895 and nonzero settled RMS are waveform guards.
The adjacent-sample step is a whole-render diagnostic containing the signal's
normal high-frequency variation; it is not a click/audibility or true-peak metric.
These probes do not establish behavior for arbitrary presets or overloaded input.

The existing de-click envelope intentionally lowers output over 20 ms, holds it
muted for 90 ms to let the effect path settle, and restores it over 120 ms.
Extending that protection to live parameters and automatic DSP therefore creates
an intentional brief volume dip. It is not sample-accurate automation or a
seamless morph, and overlapping continuous slider gestures can prolong the dip.
The main timer, physical routes, actual source-handoff host clocks and listening
experience require iPhone validation. The gain/loudness mode above now covers
shipping calculations and updates during restoration with controlled audits;
asynchronous meter delivery and spatial transitions remain follow-up work.

## Broadband and transient stock-mixer handoffs (2026-10-11)

Run `bash tests/run_playback_handoff_broadband_regression.sh`. All 648 stereo
handoffs passed (1,296 channel measurements), and the existing 216 tone cases
passed again after extending their shared transport renderer. No production
DSP or timing compensation was changed in this step.

The matrix covers 44.1/48 kHz sources, 44.1/48/96 kHz output, all nine sinc
phase/quality combinations, zero/fractional seeks, and these deterministic probes:

- Six-tone mixture: 137, 997, 3901, 8033, 12007 and 16001 Hz, with distinct phases.
- Chirp: 200 Hz to 18 kHz during the rendered half second.
- Transients: Gaussian-windowed 2/8/16 kHz cosine bursts, 0.4 ms envelope sigma,
  centered at 282 ms (inside the fade) and 390 ms (after the fade).

Signal positions are relative to the actual quantized source seek, rather than
assuming the requested fractional time is an exact source frame. The same
shipping sinc/slice/clock fixture and stock-mixer superposition reference as the
tone suite are used. Each case renders the output-block pattern
`127, 512, 63, 1024, 256` repeatedly. Gains are updated either every render block
or with a minimum 16 ms interval between updates. The latter is a deterministic
control-delay probe, not a simulation or guarantee of iPhone main-thread jitter.

| Probe | Largest absolute fade-window RMS difference | Largest steady waveform residual | Minimum best normalized correlation | Maximum mixed sample peak |
| --- | ---: | ---: | ---: | ---: |
| Six-tone mixture | 0.0490 dB | -13.187 dB | 0.976000 | 0.143944 |
| Chirp | 0.0361 dB | -8.346 dB | 0.926827 | 0.150080 |
| Transients | 0.0796 dB | -11.192 dB | 0.962004 | 0.150000 |

Measurement windows remain 360–460 ms for the completed waveform and 20–44 ms
after the scheduled replacement start for fade energy. Normalized correlation
searches integer output-frame lags from -8 through +8; every tested case selected
zero as its best lag. This is a coarse alignment result and does not imply zero
fractional delay or equal nonlinear phase. The residuals expose those differences,
including the larger minimum-phase difference near the chirp's high frequencies.

Regression guards require best correlation above 0.9, unshifted waveform
residual below -6 dB, coarse alignment within three 96 kHz graph frames, fade RMS
difference below 0.5 dB, completed-fade residual below -50 dB, no early replacement
above 1e-6 amplitude, and finite/nonzero mixed output with sample peak below 0.3.
These are transport/phase regression bounds for the specified probes, not
perceptual transparency or true-peak limits. The runner also requires an
intentionally eight-frame-shifted prepared slice to fail a broadband guard.

There was no failing production alignment case requiring a correction in this
matrix. Effect/automatic-DSP setting protection is covered above. Remaining transition
work includes asynchronous meter-driven gain changes and spatial processing. Physical host clocks, actual UI
stalls, routes, interruptions and audibility remain device-only verification.
This step changes standalone tests/documentation; the previous successful iOS
build remains the production-code build result.

## Scheduled stock-mixer waveform and seek validation (2026-10-11)

Run `bash tests/run_playback_handoff_waveform_regression.sh`. The fixture extracts
both sinc preparation and the zero-copy playback slice verbatim from shipping
source, and uses `PlaybackHandoffClock.plan` and the shipping fade-progress
function. It exercises two AVAudioPlayerNodes feeding the stock AVAudioMixerNode,
with a 96 kHz graph. The disabled custom handoff Audio Unit is not used.

All 216 cases passed (432 channel measurements): 44.1/48 kHz stereo sources,
997 Hz/12 kHz tones, all nine phase/quality combinations, seeks at zero and
0.123457 seconds (rounded down to the actual source frame), and 44.1/48/96 kHz
output. The replacement is scheduled 250 ms after the render anchor, using the
prepared frame selected by the production plan; render blocks are respectively
127/256/384 output frames. The 64 ms fade uses the shared render-frame progress.

The reference keeps the old branch rendering. A second run sums old and new at
unity; subtracting the old reference isolates the new branch through the linear
stock mixer. A muted-old reference showed different offline scheduling at
44.1 kHz, so it is not used as evidence of a shipping alignment defect. The
completed fade must match this independently reconstructed new branch below
-50 dB residual. Before 200 ms the new branch must remain below 1e-6 amplitude.

| Phase | Largest steady waveform residual | Largest absolute fade-window RMS difference | Largest absolute phase-equivalent delay at 96 kHz |
| --- | ---: | ---: | ---: |
| Linear | -20.886 dB | 0.0086 dB | 0.1152 frames |
| Minimum phase | -12.369 dB | 0.0609 dB | 0.3073 frames |
| Apodizing | -20.887 dB | 0.0086 dB | 0.1152 frames |

Residual/phase measurements use 360–460 ms after the old player starts. The
fade RMS window spans 20–44 ms after the scheduled replacement start. Reported
phase-equivalent delay is the wrapped tone phase difference, not broadband
filter group delay. Nonlinear phase and rounding a host-clock analogue onto a
96 kHz sample grid intentionally prevent an exact null. Regression bounds are
residual below -8 dB, phase-equivalent delay below 1.5 graph frames, and absolute
fade-window RMS difference below 0.3 dB; these bounds detect gross alignment or
cancellation regressions and do not certify perceptual transparency. An
intentional eight-frame content-position error must fail a waveform/phase guard,
so a successful test invocation also verifies that misalignment is detected.

No constant delay compensation was added: the measured phase depends on the
mode/frequency, and the tested fades remain within the stated bounds. The engine
now shares its fade calculation with the tests and ignores negative frame stamps
or nonfinite/nonpositive sample rates when updating gains. Timeline regressions
also verify monotonic unity-sum progress and invalid-clock rejection. The generic
iOS Debug build passed with code signing disabled.

This is an offline transport test: scheduled buffer sample times stand in for the
production `play(at:)` host timestamp, and render-block gain updates stand in for
the main-thread timer. It cannot verify physical host-clock timing, UI stalls,
DAC/Bluetooth latency or audibility. The broadband/transient extension is documented above. Automatic DSP, spatial
processing require the further full-path checks listed above. Setting-driven
EQ/effect protection is now covered by the transition suite; static effect-path
tests alone do not establish transition behavior.

## Minimum-phase fractional interpolation repair (2026-10-11)

The old implementation reconstructed a minimum-phase filter independently for
all fractional interpolation phases. Homomorphic reconstruction preserves a
magnitude response while reconstructing its phase, so it cannot retain an
arbitrary fractional delay merely because the linear input was shifted. This
interpretation of the code is supported by the before/after measurements below;
[the SciPy minimum-phase documentation](https://docs.scipy.org/doc/scipy/reference/generated/scipy.signal.minimum_phase.html)
describes the magnitude-preserving, same-length homomorphic construction.

The repaired mode uses one source-rate minimum-phase FIR, followed by fractional
windowed-sinc interpolation. Both stages are fused into the cached kernels:
`y(t) = sum_j h[j] * interpolation(t - j)`. The source history is three profile
radii and the complete kernel has four profile radii plus one taps (65/97/161
for eco/standard/master). This retains the complete convolution and correct tap
orientation instead of discarding fractional phase or clipping filter tails.
Only the source FIR is minimum phase; this document does not claim the whole
finite interpolation/output chain is a mathematically exact minimum-phase
system. The combined magnitude response has a sharper transition than the old
single-stage filter; near-cutoff attenuation is intentional and measured.

The source FIR is reconstructed once per kernel-table build with a larger cepstral FFT,
rather than doing an FFT reconstruction for every fractional phase. Per-frame
work uses a longer dot product than before; the existing 25% worker duty limit
and cancellation checks remain. Linear/apodizing modes retain their original
kernel coefficients. Prepared-audio disk cache version 3 prevents old PCM from
bypassing the corrected preparation code.

Core results (both source rates and all qualities):

| Frequency | Fundamental gain range after repair | Largest non-fundamental ratio before → after |
| --- | ---: | ---: |
| 1 kHz | -0.001005 … +0.000180 dB | -27.715 → -78.949 dB |
| 12 kHz | -0.000534 … +0.000236 dB | -6.515 → -60.073 dB |

`--core-only --boundary-only` passed all 72 frequency-response probes and all
18 stereo chunk/whole-buffer comparisons. New minimum-phase guards require
less than 0.1 dB fundamental gain error and less than -50 dB non-fundamental
energy at 1/12 kHz. The old measured implementation fails these guards, so the
suite now detects the original spectral modulation rather than only recording
it. The generic iOS Debug build passed with code signing disabled.

`--minimum-phase-only` runs the affected 162 file/PCM comparisons through
bypass, Basic and Pro graphs, including all final output rates and the shipping
sample-peak protection. All 162 comparisons passed (324 channel measurements):
maximum sample peak 0.214019, maximum absolute full-path RMS difference
0.001038 dB, and maximum impulse displacement one output frame. These are
macOS offline results for the tested signals/default settings, not device or
true-peak guarantees.
The previous full 486-case matrix below is a historical baseline for the old
minimum-phase kernels, not the repaired implementation.

The scheduled tone/seek checks above now cover the repaired kernels. Remaining
work includes changing-DSP transitions, overloaded/intersample peaks,
processing performance on an iPhone, and physical output routes. No constant timing compensation or custom
mixer activation is introduced by this repair.

## Sinc position consistency and core response (2026-10-10)

The contiguous renderer previously advanced its source position by repeatedly
adding `1 / ratio`. At 44.1 → 96 kHz, floating-point accumulation could select the
opposite side of an integer/polyphase-bin boundary from the chunk renderer's
absolute output-frame calculation. The measured minimum-phase disagreement was
as large as 0.028395 sample amplitude. `renderSincChannel` now delegates to the
same `renderSincChunk` implementation with source/output offsets of zero.
Cancellation checks and zero-padded edges remain in the shared implementation.

The boundary suite now requires exact equality for both the contiguous renderer
and the absolute-position reference, rather than only recording their difference.
All 18 stereo phase/quality/source-rate combinations passed, including the
262,144-frame chunk boundary and file edges. This eliminates the difference
between these preparation implementations. The production file/chunk path's
samples, kernel generation and handoff alignment remain unchanged; the earlier
486-comparison full-path measurements still describe that path. A new full
matrix was not needed to validate an unchanged chunk/effect path.

Run `bash tests/run_sinc_effect_path_measurement.sh --core-only --boundary-only`
for the new 72 core probes and the 18 boundary comparisons. Core probes use the
shipping whole-buffer converter without effects or Core Audio engine nodes.
They fit sine and cosine coefficients over 100–200 ms of a 250 ms stereo signal
using least squares. Fundamental amplitude is independent of phase rotation;
remaining energy measures modulation/images outside the fitted fundamental.
Inputs cover 1 kHz, 12 kHz, and 80%/96% of source Nyquist at 44.1/48 kHz; output
is 96 kHz. Only finite/bounded output and a nonzero fundamental are regression
guards; printed spectral measurements must not be described as transparency
checks passing.

| Phase | 12 kHz fundamental gain range | Largest 12 kHz non-fundamental ratio |
| --- | ---: | ---: |
| Linear | -0.000215 … +0.000047 dB | -60.071 dB |
| Minimum phase | -1.110805 … -0.562531 dB | -6.515 dB |
| Apodizing | -0.000004 … +0.000002 dB | -60.074 dB |

Minimum-phase response requires further investigation: even at 1 kHz its largest
non-fundamental ratio was -27.715 dB. Phase rotation alone cannot account for
this residual. At 96% of source Nyquist, measured fundamental attenuation ranged
up to -18.967253 dB for minimum phase and -34.517012 dB for apodizing; these are
near-cutoff measurements, so attenuation by itself is not proof of a defect.
Do not apply a single timing offset or change minimum-phase kernels until the
fractional-phase response and transition waveforms have been examined.

The existing handoff regression also passed all 36 rate/seek combinations plus
invalid-clock/short-tail cases. Physical output and protected-media playback
remain pending. The generic iOS Debug build passed with code signing disabled.
The first sandboxed build could not launch SwiftUI macro plugins; the successful
build ran outside the sandbox with the same project, scheme and source.

## Precision-sinc and effect-path measurements (2026-10-10)

Run `bash tests/run_sinc_effect_path_measurement.sh` outside the sandbox when
Core Audio cannot instantiate nodes within it. The script compiles the shipping
sinc methods extracted from `HiResPlaybackEngine.swift`, plus the shipping phase
and quality enums, kernel profiles, kernel cache and DSP helpers. Extraction
requires unique source anchors and fails if they change; no separate sinc/kernel
implementation is maintained in the test. The host adapter supplies the error
enum and invokes the existing absolute-position renderer for a reference.
Shipping macOS memory checks, cancellation points and worker throttling remain.

Coverage:

- Nine combinations: linear/minimum-phase/apodizing × eco/standard/master.
- 44.1/48 kHz stereo float inputs; 96 kHz internal processing; 44.1/48/96 kHz
  offline output. An impulse, 997 Hz sine and 12 kHz sine use differing levels
  and opposite polarity across channels.
- Compare file-backed playback against the shipping file/chunk-prepared sinc
  buffer through bypass, Basic, and Pro graphs. Basic/Pro attach the entire
  registry pipeline in shipping order, enable that tab's default effects, and
  include the shipping AUPeakLimiter settings and -1 dB post-limiter ceiling.
  Flutter is zero to make the timer-driven modulation deterministic.
- Measure impulse peak displacement, steady-state RMS ratio, unaligned null
  residual, fundamental phase-equivalent delay, and final sample peak. A
  minimum-phase conversion deliberately changes phase; a nonzero raw residual
  is a measurement, not automatically a failed test. Phase-equivalent delay is
  wrapped to one sine period and must not be read as broadband group delay.
- Reject invalid/silent output, sample peaks above 0.895 for protected graphs,
  impulse displacement beyond 5 ms, and gross level changes above 3 dB. These
  are regression guards, not perceptual transparency or true-peak guarantees.
- Cross the actual 262,144-output-frame chunk boundary with 2.8-second stereo
  signals in all nine modes at both source rates. Compare every output frame
  against the same shipping renderer invoked on the whole source using absolute
  positions. Separately report the accumulated-position legacy renderer's error.

Results: the full measurement executable passed all 486 path comparisons
(972 channel measurements) and all 18 chunk-boundary comparisons. The largest
sample peak was 0.216360. The following ranges summarize the tested default
settings and frequencies, including bypass and both effect tabs:

| Phase | Maximum absolute RMS difference | Largest raw sine residual | Maximum impulse displacement |
| --- | ---: | ---: | ---: |
| Linear | 0.000434 dB | -52.745 dB | 0.010417 ms |
| Minimum phase | 0.951530 dB | 6.019 dB | 0.929705 ms |
| Apodizing | 0.000224 dB | -52.732 dB | 0 ms |

All chunked outputs matched the absolute-position reference sample for sample.
At 44.1 kHz, the legacy accumulated-position renderer differed by up to 0.028395
sample amplitude in minimum-phase mode on the 997 Hz boundary signal; at 48 kHz
it matched. Do not infer that a minimum-phase transition is transparent from the
passing gross-regression guards. Its phase, frequency response and transition
alignment require separate investigation before compensating playback timing.

The initial full run finished its executable successfully, then encountered a
shell error because the running script's comment was edited during execution.
The runner was checked again with `--boundary-only`, which skips the slow effect
matrix after the same 18 shipping chunk-boundary comparisons. Default execution
still runs the full 486-comparison matrix.

Limits: the engine's adaptive input/output trim, loudness compensation, automatic
DSP, HRTF/spatial preparation, dither, scheduled handoffs and physical output
routes are not exercised. The graph uses fixed default settings and moderate
input levels; it does not establish overloaded-output or intersample-peak safety.
The app's production signal path and phase alignment are unchanged.

## Source-path conversion baseline (2026-10-10)

`bash tests/run_source_path_conversion_regression.sh` compares file-backed
`AVAudioPlayerNode.scheduleSegment` playback with PCM prepared through
`AVAudioConverter` and scheduled with `scheduleBuffer`. The standalone converter
uses the same default converter settings and one-buffer/end-of-stream input
contract as `HiResPlaybackEngine.convertBuffer`; it is a measurement fixture,
not a call into the complete shipping engine.

Measurement contract:

- Stereo float PCM at 44.1/48 kHz; 96 kHz stock mixer graph; final offline output
  at 44.1/48/96 kHz. No effects, output protection, or handoff fade.
- An impulse at 250 ms measures peak timing per channel. Bound common output
  delay to 1 ms and source-path delay difference to one output frame.
- 997 Hz and 12 kHz sines use opposite channel polarity and different levels.
  Compare the middle 80% of output to exclude startup/tail transients. Require
  relative and absolute RMS level errors below 0.1 dB and null residual below
  -40 dB. Also reject nonfinite, silent, and excessive output.
- This contract can be reused by desktop tests without assuming its graph is
  identical to this app's graph.

Results: all 18 comparisons passed on macOS (both channels). Source-path impulse
peak differences were 0 frames. Final conversion added a common delay of 7 frames
at 44.1 kHz and 8 frames at 48 kHz; 96 kHz output had no measured peak delay.
Steady-state sine outputs matched sample for sample (zero residual, reported as
`-inf` dB rather than an artificial numerical floor).

The sandbox prevented Core Audio node creation (`comp != nullptr`); measurements
ran outside the sandbox. A separate existing effect-audit attempt failed at the
same environment boundary, before its EQ assertion could run, so it supplies
no new evidence about the intermittent exciter failure.

Remaining work: precision-sinc preparation, the complete effects/protection
chain, seek offsets and running handoffs, desktop implementation comparisons,
and physical iPhone routes. These results do not establish hardware group delay,
true-peak safety, compressed-codec behavior, or click-free quality transitions.

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
