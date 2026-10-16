# Spatial / HRTF setting continuity — 2026-10-14

## Cause and implementation

Changed spatial settings previously rebuilt the PCM, then stopped/reset the
active player and rescheduled at its current position. This introduced a
transport discontinuity even when the new buffer was ready. Obsolete jobs also
continued full-track HRTF processing before their completion was discarded.

Spatial changes now use the existing two-player AVAudioMixerNode handoff:
retain the audible source, anchor the replacement to its render/host clock,
schedule with at least 80 ms lead, and crossfade over 64 ms of rendered frames.
The shared graph/session stays connected. The experimental custom mixer remains
disabled. Gain updates are control-rate, not sample-accurate.

- An occupied handoff, missing clock, missed deadline or short remaining tail
  retains the old source and retries the latest candidate after 50 ms. A repeat
  or seek can then accept the candidate. A paused EOF adopts it without starting
  the engine or publishing another track-ended callback.
- Commit rechecks request identity, cancellation, track URL, current pause state
  and base PCM identity. A changed SRC base triggers a rebuild from that base;
  a late spatial result cannot revert source quality. Current effect settings
  replace the worker's old snapshot when committing.
- Superseded serial jobs exit before allocating a new full-track clone. Running
  HRTF loops check cancellation every 4,096 frames. Further checks separate
  cloning, signal analysis and DSP-profile analysis. The original PCM stays
  read-only. Analysis functions themselves are not incrementally cancelled.
- A spatial request cancels the obsolete quality worker; the quality handoff
  also checks the spatial request generation. The view model can restart an
  eligible quality upgrade with the latest settings after spatial completion.
- Analysis/preload keys distinguish actual spatial processing from dry output,
  including ON/OFF and route eligibility. Cached and awaited preload results
  must match that processing state. Route changes re-evaluate spatial settings.

## Automated validation

Run `bash tests/run_spatial_transition_regression.sh` on macOS with Audio Units
available. Shipping HRTF profiles, FIR/IIR processing, zero-copy slicing and
handoff clock calculations are compiled directly from the application source.
The waveform fixture uses real AVAudioEngine player nodes and the stock mixer;
offline sample timestamps substitute for physical host-clock scheduling.

The 192 stereo cases cover:

- Natural, Frontal, Wide and Studio HRTF presets.
- Dry → spatial, spatial → dry, low → high parameters and preset changes.
- 96 kHz source/processing, 44.1/48/96 kHz output.
- Start and fractional seek (0.123457 s).
- Per-render-block controls and delayed controls spaced at least 16 ms apart.

Input combines tones, a sweep and transients with distinct left/right channels.
Independent old/new reference renders distinguish intended HRTF phase/color
changes from source timeline errors. Assertions check the unchanged prefix,
settled target null below −50 dB, 10 ms window energy above 0.15 times the lower
reference energy, finite/bounded sample peaks, adjacent-sample discontinuities,
and unchanged base PCM. All 192 cases passed:

| Measurement | Result |
| --- | ---: |
| Minimum 10 ms window RMS / lower reference RMS | 0.928537 |
| Maximum absolute sample peak | 0.124494 |
| Worst settled replacement null | −138.216 dB |

Deliberately shifting the replacement by eight source frames and deliberately
muting the output each fail the intended regression guard.

Separate state tests compile shipping spatial commit/cache methods against a
recording transport and a virtual retry timer. They cover superseding requests,
track changes, pause during preparation, occupied handoffs, new SRC bases,
repeat/paused EOF, real errors, cancellation during actual HRTF processing, and
rejection of cached or delayed preloads with a mismatched processing state.
These tests validate coordination decisions, not physical playback races.

The 48-case effect/DSP continuity suite and its unsmoothed/muted negative
controls also pass. The unsigned generic iOS Debug build passes. The separate
handoff-clock regression (36 rate/seek combinations plus invalid clocks/tails)
and playback-transport regression both pass.

## Remaining validation

⭕️ [Pending] On the affected iPhone, listen while dragging spatial/crossfeed
controls, changing all four presets, toggling OFF/Basic/Pro, and overlapping
these actions with quality upgrades, pause/seek/repeat and background return.
Check wired/Bluetooth connection changes and sustained UI/thermal/memory load.
Use `audio.spatial.committed` and `audio.handoff.*` alongside render diagnostics.
Offline results do not establish device host-clock behavior or audibility.

🟢 [Done] Extended asynchronous meter-driven gain convergence and overloaded /
reconstructed-peak probes in the [continuous combined suite](METER_HANDOFF_WAVEFORM_VALIDATION.md)
and [final-output contract](FINAL_OUTPUT_PEAK_CONTRACT.md). The earlier spatial waveform tests isolate the source handoff; shared
downstream effects have separate coverage, not every combined spatial/effect
setting. Full-track clones and analysis still consume memory and CPU. The
control-rate fade can stretch under main-queue load, and general effect bypass
changes retain their short protected level dip.
