# Final-output true-peak protection implementation — 2026-10-16

## Implementation and activation state

🟢 [Done] Implemented a final-rate, linked-channel lookahead limiter in `audio/TruePeakDSP.hpp` and a one-input `OngakuTruePeakAudioUnit` wrapper. Integrated its qualification path after the last sample-rate converter in HiResPlaybackEngine.

⭕️ [Pending] **Ordinary builds retain the existing shipping graph.** The new stage is enabled only by `SWIFT_ACTIVE_COMPILATION_CONDITIONS='DEBUG ONGAKU_ENABLE_TRUE_PEAK'`. Do not enable it for distribution before physical iPhone playback, rate/route changes, meter alignment, latency and energy validation. A previous custom-AU device playback failure makes offline success insufficient for changing this default.

The implementation and automated qualification work are complete for the stated fixtures. This is not a claim of universal −1 dBTP compliance or of validation on a physical DAC/Bluetooth route. There is no new user-facing switch.

## DSP and graph contract

- Operates at the actual final rate. In qualification builds, declickMixer performs the final SRC before the protector, which feeds the unity-gain main mixer at the same rate. Effects and their processing rate remain upstream.
- Eight-phase, 129-tap (64-sample radius) Blackman-windowed sinc detector, normalized per fractional phase. Detection links all supported channels to one gain plan.
- Four milliseconds of gain lookahead plus the detector radius. Latency is 241 frames at 44.1 kHz, 256 at 48 kHz and 448 at 96 kHz (approximately 5.465/5.333/4.667 ms). The AU reports latency and tail time; pipeline diagnostics include the delay in processing-rate frames. Both source-handoff branches share this downstream delay.
- Falling gain is anticipated with a linear lookahead plan; release approaches unity with a 60 ms time constant. Detector target is −1.5 dBFS, reserving 0.5 dB for reconstruction/envelope uncertainty against the −1 dBTP goal. Quiet signals do not receive a permanent extra trim.
- Storage, kernels and buffers are allocated before rendering. Processing uses fixed channel arrays/ring buffers without callback allocation, locks, Objective-C/Swift dispatch or logging. Format support is bounded to 1–8 channels and 8–384 kHz; frame resources are bounded to 65,536 frames. This is a complexity bound, not a mobile CPU budget measurement.
- Nonfinite input samples become zero. Reset clears audio, queued gain plans and release state. The AU validates bus/format/buffer capacities, supports host-owned null output buffers and retains delayed audio across input-silence flags. Resource deallocation frees owned buffers without invalidating the captured storage object's address.
- The candidate stage is independent of OFF/Basic/Pro. It does not modify source files, replace source timing, or process protected system-Music playback.

The first 49-tap detector failed the Nyquist-near transient tests. Increasing detector support to 129 taps addressed that under-read; those failed results were not accepted as qualification. The independent engineering meter uses a different length (97 taps) and 16 phases, and an external meter checks the captured PCM separately.

## Qualification results

| Check | Result |
| --- | --- |
| Final-output adversarial matrix | All 84 cases pass the −1 dB reconstructed ceiling gate |
| Maximum 16x reconstructed peak | 0.847640, approximately −1.436 dBFS reconstructed |
| Independent FFmpeg ebur128 true-peak meter | All 84 captured WAV files ≤ −1 dB; maximum reported −1.5 dBFS |
| External meter calibration | Tapered amplitude-1.12 Fs/4 sine reports +1.0 dBFS, within 0.2 dB of the theoretical +0.984 dB peak |
| Protected nonlinear DSP / source handoffs | 18 reference/transition pairs: bypass, Exciter and Warm; three output rates; quiet/hot input |
| Maximum protected transition sample difference | 2.3841858e-7 against the matched non-handoff reference |
| Maximum protected transition reconstructed peak | 0.844502 |
| Existing gain/loudness continuity | 72 cases and duplicate/inactive gain / muting / interpolation negative controls pass |
| Existing scheduled source handoff waveforms | 216 cases and intentional eight-frame misalignment control pass |
| DSP / real AU memory and lifecycle | AddressSanitizer + UndefinedBehaviorSanitizer checks pass |
| Actual iOS simulator AU | Quiet PCM, latency, formats, null buffers, invalid bus/block and resource lifecycle pass on SE (3rd generation), iOS 26.2 |
| iOS builds | Qualification-enabled and ordinary Debug simulator builds pass |

Quiet samples match exactly after shifting by the declared latency. Direct DSP processing also produces sample-identical output with 1-frame versus 4096-frame blocks, preserves the linked stereo ratio, sanitizes nonfinite values and performs zero counted allocations during processing. These tests do not establish subjective transparency of active limiting.

The source-handoff test compares two identical, aligned players with complementary gains against one player through matched effect/protection graphs. It establishes continuity for that controlled overlap, not every asynchronous device host-clock event or effect topology change. Native iOS simulator testing exercises the real AU directly, not the device's live audio route.

Evidence: [protected matrix](measurements/final-output-protected-2026-10-16.json), [independent meter](measurements/final-output-independent-meter-2026-10-16.json), [earlier failing baseline and contract](FINAL_OUTPUT_PEAK_CONTRACT.md). FFmpeg's [ebur128 filter documentation](https://ffmpeg.org/ffmpeg-filters.html#ebur128-1) describes true-peak mode. The independent check is not a certified ITU meter-conformance qualification; formal conformance material and hardware measurements remain pending.

## Reproduce

```sh
TRUE_PEAK_SANITIZERS=1 bash tests/run_true_peak_unit_regression.sh
bash tests/run_protected_graph_regression.sh
ONGAKU_PEAK_PCM_DIRECTORY=/private/tmp/OngakuProtectedPCM \
  bash tests/run_final_output_peak_regression.sh --protected --require-ceiling /private/tmp/protected-peaks.json
python3 tests/verify_true_peak_meter.py /private/tmp/OngakuProtectedPCM /private/tmp/independent-peaks.json
bash tests/run_dsp_transition_regression.sh --gain-path
bash tests/run_playback_handoff_waveform_regression.sh
```

The ordinary matrix runner without `--protected` still measures the previous protection and records its ceiling failures. Keeping that baseline makes accidental omission of the new stage visible to `--require-ceiling`; bypassing the limiter for the separate overload control is also required to exceed full scale.

## Remaining device qualification

⭕️ [Pending] Live sound, pause/seek/stop/repeat and final tail delivery; CPU/GPU/energy under UI and thermal load; wired/Bluetooth/USB rate and channel changes; graph reconfiguration at a new final rate; post-effect meter-window alignment after the additional latency; device voice-processing or downstream conversion; full desktop signal-path integration; formal BS.1770 conformance vectors. Route changes must not leave an unmeasured SRC after protection. These are release-enablement gates, not completed checks.
