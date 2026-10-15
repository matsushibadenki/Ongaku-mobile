# Delayed meters during spatial / quality handoffs — 2026-10-15

## Reproduced problem and repair

The combined fixture failed against the previous code with
`Shared effect/gain changed during source handoff`. An effect parameter ramp
started before a source handoff continued writing the shared effect graph and
gain stage during its scheduled lead and fade. Automatic-DSP writes had their
own guard, but ordinary effect steps and gain planning did not.

The engine now waits at each parameter step while a handoff is pending, without
consuming a step or losing the latest target. A new protected bypass request
also waits before muting the output. Gain planning independently refuses writes
during that interval. A source handoff cannot begin during an existing protected
effect fade; it uses the existing cancellation/defer path and retains the
original source. The spatial caller retries its current candidate. Quality
upgrade callers retain their existing retry policy.

Once the handoff completes, the remaining parameter steps resume together with
queued DSP changes. A superseding setting replaces the target, and stopping
invalidates the waiting callbacks. General effect bypass still has its existing
short protected fade; this change does not claim that bypass itself is inaudible.

## Waveform fixture

Run `bash tests/run_meter_handoff_waveform_regression.sh`; `--quick` runs the
control-state checks and one spatial waveform case. The fixture compiles the
shipping HRTF, precision-sinc, slicing, clock-plan, effect interpolation, meter
store/validation and gain-law code. It renders actual AVAudioPlayerNodes,
AVAudioMixerNode, the shipping Equalizer effect, automatic EQ, gain stages,
limiter and ceiling through a 96 kHz graph. The equalizer uses a flat spectral
setting and a small trim change, with its ambience branch disabled for a
deterministic sample comparison.

The 42 stereo cases cross seven source paths with 44.1/48/96 kHz output and two
initial positions: zero with per-block fade controls, and 0.123457 s with controls
spaced at least 16 ms apart. Those seek/control choices are paired, not a full
independent cadence matrix. Output block sizes vary from 127 to 512 frames.

- Spatial enable/disable, Natural → Frontal and Wide → Studio (all four presets).
- File-backed playback → shipping precision sinc at standard quality: linear
  and apodizing from 44.1 kHz, minimum phase from 48 kHz. Eco/Master and other
  input/phase combinations retain their separate existing coverage.

Stereo input combines distinct tones, a sweep, bursts and a quiet-to-loud
transition. Separate offline renders of the same shipping effect provide real
pre-trim PCM peak/RMS observations. The adversarial stream pairs an old quiet
input window with an old loud output window, delivered during the scheduling
lead, crossfade and after completion. Fresh aligned observations from the new
PCM then arrive with 40 ms latency, followed by a reordered old callback.
Reference and candidate graphs receive identical fresh observations and user
parameter/DSP requests; the reference omits the unusable old deliveries.

The fixture explicitly invokes the shipping gain consumer every 20 ms. This is
a stress stimulus, not a new periodic controller in the app. Transport state and
delivery deadlines use a virtual clock; offline sample scheduling substitutes
for device host clocks. PCM observations are replayed from calibration renders,
not collected from real-time iOS tap callbacks or a closed feedback loop.

## Results

All 42 cases passed (84 rendered stereo reference/candidate paths):

| Measurement | Result |
| --- | ---: |
| Maximum reference/candidate sample difference | 0.000000000 |
| Minimum 10 ms candidate/reference RMS ratio | 1.000000 |
| Maximum absolute output sample peak | 0.504885 |

Assertions require finite output below 0.895 sample peak, no silent 10 ms
windows through/after the handoff, identical gain-write times and values, no
shared effect/gain writes during the handoff, and completion of the latest
effect/DSP request. Zero sample difference means unusable delayed readings add
no waveform change in these cases; it is not a claim that HRTF/SRC produce
identical sound or that every possible handoff is inaudible.

Four deliberately broken controls all fail: accepting stale/misaligned meters,
an eight-frame replacement offset, output muting during the fade, and allowing
gain writes during a handoff. Additional state checks pass for a protected
bypass waiting on a handoff, successive replacement requests, restoration after
release, and stopping while waiting. The generic iOS Debug build passes.
The existing 48-case effect/automatic-DSP continuity regression and its
unsmoothed-write/output-muting controls also pass after the repair.

## Continuous PCM feedback extension — 2026-10-15

Run `bash tests/run_meter_handoff_waveform_regression.sh --continuous`.
`--continuous --quick` runs three spatial cases plus peak calibration, safety
and convergence probes; it intentionally omits the fault-injection subprocesses.
The original command still runs the 42 replay cases and their four controls.

### Collection and delivery contract

`tests/ContinuousMeterHandoffRegression.swift` inserts identity EQ collectors
at the shared source output, effect-chain input and effect output. Core Audio
post-render notifications copy the **actual PCM from the current render**;
contiguous sample timestamps and complete stereo buffers are required. The
collector is serial, allocating **offline test instrumentation**, not a proposed
real-time callback implementation. No AVAudioEngine tap scheduling is simulated
by these notifications.

Every complete 960-frame (10 ms at 96 kHz) input/output window is measured and
submitted to the shipping meter store 40 ms after its end. The extracted shipping
audit validator, gain smoothing and gain-stage writes consume these windows at
an explicit 20 ms test cadence; gain changes affect subsequent rendered PCM.
This is a closed feedback measurement, unlike the calibration replay above.
It does not add a periodic gain controller to the app.

The reference uses the legacy store. The candidate uses the modern store and
also receives duplicate/reordered windows 25 ms later and stale windows
887.5 ms later. Both receive the same valid windows, effect requests and DSP
profile. Source handoff begins at 300 ms with fade controls spaced at least
16 ms apart. Requests at 220 ms wait for the pending handoff; the shared graph
must remain unchanged until completion, then apply the latest targets. Output
blocks vary between 127 and 512 frames.

### Matrix and phase/latency interpretation

The 36 paired stereo cases cover:

| Dimension | Values |
| --- | --- |
| Source replacement | Dry → Frontal HRTF; 44.1 kHz file → standard minimum-phase precision sinc |
| Effect change | Exciter intensity; Space reverb preset and predelay; Warm disabled → enabled |
| Program level | Ordinary; overloaded floating-point input, including quiet/loud transitions and a quiet gap with residual effect tails |
| Output rate | 44.1, 48, 96 kHz, with 96 kHz internal processing |

Each render lasts 1.6 seconds from a fractional 0.123457-second seek (rounded to
source frames). Signals include distinct stereo tones, a sweep component and an
Fs/4 component with a pi/4 phase offset. Warm flutter is zero so wall-clock
modulation does not contaminate deterministic comparisons. Warm's reported
algorithmic latency changes from 0 to 48 internal frames on this host. Space's
wet predelay and reverb change while its dry-path latency remains zero.
Other HRTF presets, sinc modes and seeks retain their separate existing suites;
this is not a full cross-product of every effect/parameter.

Source PCM is compared **before** effects, separately from the processed output.
Processed output is compared to a reference with the **same intended effect
and HRTF/sinc changes**, never to dry or differently filtered PCM. Thus a reverb
tail, minimum-phase filter or Warm latency is not classified as a source offset.
An intentional eight-frame replacement error must still fail the source test.
These comparisons detect regressions relative to matched processing; they do
not prove that an intentional topology/phase transition is inaudible.

### Reconstructed peak contract

`ReconstructedPeak` is an independent test-only windowed-sinc interpolator:
8x and 16x phases, a 48-sample radius, Blackman window and unity DC normalization
per phase. Every original sample contributes to the maximum. Interpolation is
restricted to positions with a full kernel; the outer 48 samples are not
reconstructed, avoiding artificial silence at cropped stream boundaries. All
handoffs/effect changes and overload transitions lie within the measured region.

A tapered Fs/4 sine of amplitude 1.12 verifies an approximately 0.791960 sample
peak and 1.120217 reconstructed peak, including a known between-sample overload.
8x/16x peak differences must remain below 0.05 dB in every combined case. This
is a documented reconstruction estimate, **not a certified ITU true-peak meter**
and not a new oversampled limiter.

Three additional final-safety renders drive the shipping limiter/ceiling
directly with peaks up to 4.0 (approximately +12 dBFS), high-frequency sines,
multitones and level steps. Bypassing normalization here ensures that the
limiter really encounters overloaded input. Final output, including SRC, must
remain finite and below 0 dBFS reconstructed peak in these probes.

### Results and regression guards

All 36 pairs passed on the local macOS Audio Units. Each render collected 160
continuous windows; 38–54 distinct observations reached the gain consumer after
handoff/parameter invalidation. Reference/candidate source and processed sample
differences were zero; gain-write timing and values also matched. Latest settings
completed, shared writes waited for handoff completion, and settled 10 ms windows
contained audio. Warm enable retains its deliberate protected fade, so these
assertions do not incorrectly require full volume during that fade.

| Combined output measurement | Maximum |
| --- | ---: |
| Absolute sample peak after final SRC | 0.903075 (−0.886 dBFS) |
| Reconstructed peak, 8x and 16x | 0.967822 (−0.284 dBFS) |
| Difference between 8x and 16x estimates | 0.017507 dB |

The largest reconstructed peak occurred for the overloaded HRTF/Warm case at
96 kHz. All measured cases stayed below 0 dBFS, but the result explicitly rules
out interpreting the current −1 dB internal sample margin as a −1 dBTP ceiling.
The separate +12 dBFS safety probes measured reconstructed peaks of 0.707228,
0.774082 and 0.797167 at 44.1, 48 and 96 kHz respectively. These are bounded
fixture results, not universal output guarantees.

A continuous +6 dB flat-EQ probe converged to the shipping weighted measurement
target of **4.8 dB**. For the Space overload case, omitting feedback changed the
output by up to **0.15775332** in sample amplitude: collected PCM demonstrably
influences gain rather than merely populating an unused store. During a quiet
gap, residual reverb can produce a large simultaneous-window level ratio; this
is a gain measurement, not evidence of a source timeline error.

Four deliberate defects are rejected: eight-frame source offset, substituting
callback delivery time for PCM time, muting output, and bypassing the final
limiter. Original replay coverage is retained. No production audio change was
required by these new comparisons; the measurement runner was extended and its
no-argument path verified. No new iOS app build is claimed for this test-only
extension.

## Remaining validation

🟠 [Next] Establish final-output true-peak protection requirements and test more
adversarial bandwidth/phase/transient combinations before claiming a -1 dBTP
ceiling. The existing -1 dB **internal sample** margin does not guarantee -1 dB
at final output after sample-rate conversion or between samples. Coordinate this
measurement contract with the separate Ongaku desktop signal path.

⭕️ [Pending] On physical iPhone routes, verify tap timestamp availability and
window alignment, actual host-clock scheduling, sustained UI/thermal load,
Bluetooth, pause/seek during handoff and foreground return. The user's original
audible interruptions cannot be fully reproduced by this offline fixture.
