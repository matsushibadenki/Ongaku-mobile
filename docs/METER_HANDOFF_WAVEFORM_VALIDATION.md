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

## Remaining validation

🟠 [Next] Extend to independently measured true-peak/overloaded output and
nonlinear/latency-changing effect combinations. Replay here isolates bad meter
delivery; continuously collected meter feedback and gain convergence under
changing program material still need separate measurement.

⭕️ [Pending] On physical iPhone routes, verify tap timestamp availability and
window alignment, actual host-clock scheduling, sustained UI/thermal load,
Bluetooth, pause/seek during handoff and foreground return. The user's original
audible interruptions cannot be fully reproduced by this offline fixture.
