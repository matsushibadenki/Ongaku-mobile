# Effect-meter delivery and gain planning — 2026-10-15

## Findings and changes

Each effect tap previously stored only peak/RMS levels. Input/output snapshots
could describe different PCM windows, or a previous setting/source, yet be
compared as an effect gain. A failed nonblocking snapshot read also returned
the previous audit. Gain planning could repeatedly advance smoothing using the
same observation. Retired tap closures accessed the engine's current store,
allowing late old-graph deliveries to write into a replacement store.

The meter stores now retain the PCM host timestamp and buffer duration. Audit
refresh accepts input/output windows only when their starts and durations agree
within 0.1 ms, their start is at most 250 ms old, and their PCM was rendered
after the latest invalidation. Invalid/nonfinite and future windows are rejected
(20 ms allowance for render-ahead). The limits favor rejecting uncertain data;
they are not calibrated claims about all iPhone routes or Audio Unit latencies.

Settings, automatic DSP/loudness writes, seek/reschedule, prepared-source
adoption, handoff completion, meter replacement and analysis gating invalidate
earlier audits and their accumulated smoothing. Measurements are not used
during a pending source handoff. Gain estimation requires all enabled stages
to have valid, aligned observations; repeated observations do not advance
smoothing. Without valid measurements, the existing effect estimates and final
limiter/ceiling remain responsible for gain planning and output protection.

Callbacks capture their installed store. Nonblocking writes reject older
timestamps, so reordered deliveries cannot overwrite newer observations. No
audio render path waits for a meter lock. These changes do not add a periodic
adaptive-gain controller or change the playback graph.

## Verification contract

`bash tests/run_meter_delivery_regression.sh` extracts the shipping audit
refresh, invalidation and gain methods and compiles the actual legacy/modern
meter stores. A virtual host clock and explicit arrival ordering exercise fresh
measurements, expiry, an 887.5 ms delayed delivery, pre-change PCM delivered
after invalidation, misaligned stage windows, reordered writes, handoff
suppression, unavailable stores and replacement-store isolation. Finite/timing
guards cover missing/future timestamps and different buffer durations. A
deliberately disabled freshness check must fail.

Repeated reads are checked before smoothing has settled. A separate sequence of
26 fresh observations at 20 ms intervals must converge monotonically to the
4.8 dB reference boost within 0.001 dB, without overshoot.

Both store implementations passed these checks. The converged value was
4.799822 dB; repeated reads preserved the previous gain exactly, and deliberately
removing freshness rejection failed the expected expiry assertion. The unsigned
generic iOS Debug build also passed.

This is deterministic coordination/gain-law coverage. It does not reproduce
actual device tap scheduling or render audio. The separate
`bash tests/run_dsp_transition_regression.sh --gain-path` renders the existing
72 stereo gain/effect cases with contemporaneous controlled observations; it
does not establish delayed-meter end-to-end waveform behavior.

All 72 cases passed at 44.1/48/96 kHz output, along with deliberate unsmoothed
parameter changes, duplicate gain planning, inactive-only gain writes and output
muting controls. The existing finite/peak, 10 ms window energy, restoration and
gain-range assertions remain enabled.

## Remaining work

🟢 [Done] Add 42 combined spatial/SRC waveform cases with delayed/reordered
PCM meter replay and shared effect/gain stages. Fix parameter/gain writes
during pending handoffs; see [combined validation](METER_HANDOFF_WAVEFORM_VALIDATION.md).

🟠 [Next] Extend to continuously collected meter feedback, overloaded/true-peak
signals and nonlinear/latency-changing effects. Preserve the distinction between
source timeline alignment and intended phase/latency changes.

⭕️ [Pending] Validate host timestamp availability, inter-stage window alignment,
audit availability and audibility on physical iPhone routes, including Bluetooth,
background/foreground transitions and sustained UI/thermal load. The original
reported interruption is not established as being caused by stale meters.
