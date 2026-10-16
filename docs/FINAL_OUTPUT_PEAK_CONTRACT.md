# Final-output peak contract v1 — 2026-10-16

## Required behavior

The proposed local-PCM playback target is **−1 dBTP at the final rendered output**, after effects, normalization, handoff mixing, volume and final sample-rate conversion. The existing internal −1 dB sample trim is not this guarantee. OFF/Basic/Pro must share the same protection boundary. Do not change audio files, run analysis on the UI thread, or compensate by applying an arbitrary additional permanent trim.

An implementation must handle stereo independently for measurement and link limiting gain to preserve stereo balance. Test at 44.1/48/96 kHz output, route/format changes, arbitrary rendering blocks, quiet signals, overloads, latency/tails, pause/seek and source transitions. A future lookahead/oversampled limiter must preallocate callback storage, bound CPU/memory, account for latency in handoff timing and leave quiet/bypassed audio unchanged apart from declared latency. It must protect the final conversion, not only the 96 kHz input. The contract applies to the local AVAudioEngine path; protected system Music output is not processed by this graph.

For release qualification, use a validated meter implementing ITU-R BS.1770 Annex 2 (or demonstrated equal/superior accuracy) and its applicable conformance material. The current test interpolator is an engineering regression estimate, not a certified meter. Normative reference: [ITU-R BS.1770](https://www.itu.int/rec/R-REC-BS.1770/en). The reference defines measurement, not a limiter design or a mandatory playback ceiling; −1 dBTP here is the proposed Ongaku target.

## Executable shared measurement

Run `bash tests/run_final_output_peak_regression.sh /private/tmp/ios-peaks.json`.
Run `bash tests/run_final_output_peak_regression.sh --desktop /private/tmp/desktop-peaks.json` against the checked-out desktop repository. Override `ONGAKU_DESKTOP_SOURCE` to point to its AudioEffectNode.swift if necessary. The runner extracts the real EffectOutputProtection class read-only, without changing desktop files or substituting its parameter configuration. This coordinates a shared executable contract across the separate implementations; it does not test desktop's entire source/effect/normalization graph.

The same generator and recorder are used for both implementations:

- Input: 96 kHz stereo float, 16,384 frames, a 512-frame start ramp and 2,048 trailing silent frames; output adds a further 2,048-frame tail.
- Output: 44.1/48/96 kHz, nonuniform 127/512/61/256-frame render blocks.
- Tones: 0.249/0.45/0.49 times output rate, phases 0/π⁄4/π⁄2, an additional 0.31-radian right-channel phase offset.
- Other signals: impulses at frames 4095/8193, alternating samples, sign-changing step, six-tone mixture and sweep; channel polarity differs.
- Each signal at amplitudes 0.8 and 4.0: 84 cases per implementation.
- Capture after the final SRC. Include every original sample and reconstruct interior samples at 8x/16x using a 48-sample-radius Blackman-windowed sinc, normalized per phase. Do not invent discontinuities by padding cropped regions.
- Calibration: tapered Fs/4 sine, known 1.12 intersample amplitude. 8x→16x estimates must differ by less than 0.08 dB in this adversarial matrix; the older continuous-feedback suite retains its own tighter limits. This convergence test does not eliminate finite-kernel or bandwidth error.
- Negative control: bypass the real limiter for a 4.0-amplitude 997 Hz signal; the reconstructed peak must exceed 2.0, demonstrating that the test sees protection defects.

The ordinary runner passes when measurement/calibration/render integrity checks pass, even if the proposed ceiling is exceeded. `--require-ceiling` additionally rejects estimates above −1 dB. Do not interpret the ordinary runner's PASS as a true-peak protection pass. This opt-in gate is intended for the eventual limiter implementation.

## Baseline result

Both 84-case runs completed on macOS Apple Audio Units. Each recorded six cases above the proposed −1 dB target; four exceeded a reconstructed amplitude of 1.0. Maximum reconstructed amplitude was **1.175459 (approximately +1.404 dBFS reconstructed)** for the 96 kHz alternating signal at input amplitude 0.8; its output sample peak was only 0.713001. Thus the problem is visible without forcing the limiter into sample overload.

Maximum 8x→16x estimate difference was 0.078087 dB. The largest per-case iOS/desktop estimate difference was 0.017230 amplitude; these separately initialized Audio Unit runs are not sample-identical and the shared contract does not assert a null. Both have the same worst-case failure and require actual final-output protection. The desktop runtime normally processes at file rate; this shared stage-level probe deliberately uses 96 kHz input for comparability. Other desktop processing rates remain pending.

Full observations: [iOS protection](measurements/final-output-ios-2026-10-16.json), [desktop protection](measurements/final-output-desktop-2026-10-16.json). Production limiter/gain settings were not silently changed based on a finite fixture matrix.

🟢 [Done] Establish the shared contract, expand adversarial probes and measure the shipping protection classes independently.

🟢 [Done] Implemented the bounded protector and qualification path. All 84 protected cases, independent-meter checks and protected DSP/handoff tests pass; see [implementation validation](TRUE_PEAK_PROTECTION_VALIDATION.md). Ordinary builds retain the baseline until device qualification.

⭕️ [Pending] Physical iPhone/Bluetooth/DAC validation, device output formats and desktop full-path/source-rate coverage. No claim is made about DAC analog reconstruction, codec re-encoding or system Music protection.
