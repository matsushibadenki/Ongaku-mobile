# Effect control continuity and OFF mode — 2026-10-14

## Findings

The previous live-update path applied a 20 ms fade-out, 90 ms silent hold and
120 ms restore to *every* audible parameter, automatic-DSP and loudness change.
A continuous gesture could restart this envelope before restoration finished.
Entering the Effects screen also requested a separate output fade. These are
application-generated level dips, independent of the render/tap scheduling
warnings investigated previously.

The view model also requested spatial reprocessing on every Basic/Pro change.
The engine rescheduled its player even when the applied spatial settings were
identical, or both old and new settings were disabled. Such requests now return
without touching the schedule, while still invalidating an older spatial job.

The user could not read the transient foreground error. Its exact source has
not been reproduced. Inspection found an unguarded spatial-worker failure
callback and a recovery-exhaustion path that did not recheck actual playback.
Both now reject stale outcomes. UI errors are logged as `ui.playback.error`;
alerts wait for an active scene and 300 ms of unchanged error state. A cleared
or replaced error cannot present later; a persistent error remains visible.
The Effects controls retain their identity across foreground/tab transitions.

## Current behavior

- Same-enabled-state effect parameters, automatic EQ and loudness compensation
  interpolate over eight control updates, nominally 10 ms apart. Only one next
  callback is queued; overlapping requests replace the target. The output mixer
  volume stays unchanged. Gain planning runs once per interpolation step when
  audible processing changes; disabled-only edits do not alter gain.
- Effect enable/disable and reapplication retain a protected commit, shortened
  to an 8 ms fade-out and 16 ms restore, without the 90 ms silent plateau.
  **These bypass changes still include a brief level dip.** They are not
  sample-accurate crossfades and are not claimed to be inaudible on hardware.
- Stop invalidates queued interpolation/envelopes and resets output volume.
  Shared automatic EQ/loudness updates still wait for source-handoff completion.
- OFF is a persisted third mode beside Basic and Pro. It bypasses registry
  effects, automatic DSP, loudness compensation and the selected spatial
  settings. Switching back restores saved settings; OFF never overwrites them.
  The engine also rejects pre-OFF effect/DSP settings delivered by a late
  background result and selects the unprocessed base PCM from prepared data
  while OFF, including the scheduled handoff path.
  Output normalization/protection and sample-rate conversion remain active.
  A/B reference state continues to control its existing bypass behavior.
- Mode help is behind an information button, with English, Japanese and
  Simplified Chinese text. Automatic-DSP controls show OFF and are disabled in
  OFF mode. Changing display/lifecycle state alone no longer fades playback.

## Automated coverage

`bash tests/run_dsp_transition_regression.sh` compiles shipping engine methods
and effect nodes against a virtual control timer and macOS offline Audio Units.
It also extracts shipping view-model selection/computed-setting logic against a
recording engine, using a disposable UserDefaults suite.

The 48 stereo cases cover Basic/Pro at 44.1/48/96 kHz output, a 96 kHz processing
graph, superseding parameters, omission/disable, strength/voicing, handoff
waiting, stop/restart, 40 successive gesture requests and OFF/restore. Assertions
check exact output-envelope preservation for continuous controls, 10 ms PCM
window energy (above one tenth of the lower reference/settled RMS), latest target
retention, finite output, sample peak <=0.895, and restoration after protected
commits. OFF/restore checks neutral automatic EQ, bypassed loudness, disabled
modules, unchanged playing state and restoration of the original parameters.
A delayed pre-OFF settings/profile request must not re-enable processing.
The selection fixture verifies mode persistence, saved spatial/parameter values
and A/B reference interaction. All passed.

`bash tests/run_dsp_transition_regression.sh --gain-path` exercises 72 stereo
quiet/hot source cases with shipping input/output gain laws, source analysis,
controlled audit snapshots, automatic EQ and loudness. Assertions cover every
interpolation step, coalescing, gain/audit bounds, disabled-only edits, non-unity
output preservation and 10 ms PCM continuity. Deliberate controls must reject
immediate unsmoothed writes, duplicate gain planning, inactive-only gain writes,
and forced output muting. All 72 cases and all four negative controls passed.

`bash tests/run_playback_transport_regression.sh` passes, including rejection of
cleared, replaced, inactive and cancelled alert requests while allowing a
persistent current error. The iOS Debug device build passes; all three
localization files pass `plutil -lint`. Handoff-clock regression and navigation
presentation regression also pass (36 timeline combinations and 1,800 telemetry
publications without Library/Search refresh, respectively).

## UI and remaining limits

After the report that OFF/Basic/Pro needed a prolonged press, the segmented
Picker was replaced with three native plain Buttons. Each has an equal-width,
44 pt minimum-height rectangular hit area, a localized label and selected
accessibility state. Mode/card insertion animations were removed from their
common ancestor; mode selection still calls the existing synchronous view-model
method, without a long-press gesture or UI debounce. The audio ramps are
independent of this visual update. The device-specific gesture failure was not
reproduced in this environment, so actual short-tap/scroll behavior remains a
device check rather than a proven cause attributed to SwiftUI.

The isolated Simulator fixture uses the shipping ContentView with service
bootstrap disabled and a deterministic view model. OFF on iPhone SE
(3rd generation) and Basic on iPhone 16 Pro Max were rendered and inspected;
the mode selector and 44 pt help button fit one row within the side margins. This is layout
validation, not proof of physical audio behavior or MediaPlayer recovery.

⭕️ [Pending] On the affected iPhone, listen while dragging Basic/Pro controls,
automatic DSP and hardware volume; toggle OFF/Basic/Pro rapidly, pause/resume,
lock/unlock and return after extended inactivity. Check the new error log if an
alert returns. Real main-queue load can stretch the nominal control intervals.

🟢 [Done] Changed spatial/HRTF buffers now use a clock-aligned two-player
handoff, with cancellation and stale-result guards. All 192 stereo waveform
cases and deliberate timing/muting faults pass; see
[spatial transition validation](SPATIAL_TRANSITION_VALIDATION.md).

🟢 [Done] Extended asynchronous meter/gain and overloaded/reconstructed-peak
probes; see [continuous measurements](METER_HANDOFF_WAVEFORM_VALIDATION.md) and
[final-output contract](FINAL_OUTPUT_PEAK_CONTRACT.md). The original continuity
fixture supplies deterministic audit snapshots and does not validate device
Audio Units, Bluetooth/DAC latency, or psychoacoustic click thresholds.

Update, 2026-10-15: timestamped meter stores and shipping gain logic now have
separate delayed/stale/reordered-delivery checks; see
[meter delivery validation](METER_DELIVERY_VALIDATION.md). The subsequent
[combined waveform fixture](METER_HANDOFF_WAVEFORM_VALIDATION.md) passes 42
spatial/SRC handoffs with delayed PCM meter replay and fixes shared parameter/
gain writes during the source fade. Continuous device tap feedback remains
separate follow-up work.
