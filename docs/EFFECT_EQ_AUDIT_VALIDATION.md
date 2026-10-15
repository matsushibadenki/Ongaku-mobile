# macOS EQ audit readback validation

Date: 2026-10-15 (JST). Host: macOS 27.0.1 (26A434), Xcode 27.0 (27A266a).
The standalone executable compiles the shipping effect implementations.

## Cause of the intermittent assertion

The old `EQ bands enabled exciter` assertion used only
`AVAudioUnitEQFilterParameters.bypass`, immediately after attaching the effect.
Repeated creation reproduced that exact condition: in an initial 500-iteration
probe, seven Exciter band readings returned `true` while the underlying
NBandEQ bypass parameter was `0` (enabled), with `AudioUnitGetParameter`
returning `noErr`. A second probe also reproduced the discrepancy in Warm.

A two-millisecond wait and fetching `eq.bands` again did not resolve those
readings. Connecting the graph often resolved them, but a stricter connected
check still failed at iteration 108 with AU bypass `0` and wrapper bypass
`true`. Merely delaying the assertion or retrying the whole audit is therefore
not a reliable fix.

The demonstrated cause of the audit failure is inconsistent AVAudioUnitEQ
wrapper readback, not evidence that the corresponding Audio Unit band was
bypassed. The private implementation inside AVFAudio is not visible here; this
investigation does not claim an exact internal cache/race mechanism or the
same behavior on every OS version.

## Correction and regression coverage

`EffectEQLifecycleAudit.issues` now checks the actual NBandEQ bypass parameter
for every band, requiring a successful read and value exactly `0`. Any error,
NaN or bypassed band fails with its node, band, status and values. Wrapper
readings remain in diagnostic logs; they are not substituted for the render
unit's state. Production effect settings and signal routing are unchanged.

The repeatable lifecycle suite covers attachment, complete connection/manual
rendering setup, Smooth/Open parameter application, disable, and restoration
after deliberate faults at 44.1/48/96 kHz. For each EQ instance, it deliberately
bypasses a rotating band through both the wrapper and Core Audio APIs and
requires the same validator to identify that exact band. The default 20
iterations add 280 such negative controls; stress mode uses 500 iterations and
7,000 negative controls.

When wrapper discrepancies occur, the same EQ instance and affected band are
also rendered in isolation **before** the deliberate bypass writes. The test
preserves that band's bypass state, configures a 1 kHz / +6 dB diagnostic
filter, and measures stereo PCM gain. A second render deliberately bypasses
the band and must return to unity. Seven additional EQ instances (four Exciter,
three Warm) receive the same enabled/bypassed waveform comparison on every run.
These probes verify the bypass assertion; the full matrix continues to test
the effects' actual shipping filter curves and complete processing chains.

During development, a probe that retyped a Warm low-pass into a parametric EQ
through the wrapper produced 0 dB instead of +6 dB. Instrumentation reproduced
this at iteration 131: filter type and frequency had changed, but the AU gain
was still `0` and bandwidth `0.5`, despite wrapper writes requesting `6` and
`1`. The diagnostic filter setup now writes those four parameters through
Core Audio and checks each readback before rendering. It does not rewrite the
band's bypass for the enabled measurement. This removes an invalid probe
configuration rather than relaxing the PCM threshold.

No sleep, retry-until-pass or corrective bypass write is used to accept the
shipping initialization. The full audit's reported final-case count is also
corrected from 60 to 90 to include OFF alongside Basic and Pro.

## Commands

```sh
bash tests/run_effect_audit.sh                    # 20 lifecycle iterations + full matrix
bash tests/run_effect_audit.sh --eq-only          # lifecycle and isolated EQ PCM checks
bash tests/run_effect_audit.sh --eq-only --eq-stress
bash tests/run_effect_audit.sh --eq-stress        # 500 iterations + full matrix
```

The host must allow Audio Unit instantiation; the filesystem sandbox alone
cannot run this audit. Existing SDK deprecation warnings for Audio Unit access
remain visible; the audit still supports the repository's older SDK targets.

## Final results

`bash tests/run_effect_audit.sh --eq-stress` passed on the host above:

| Check | Result |
| --- | --- |
| Lifecycle iterations | 500 (Exciter and Warm each) |
| Wrapper discrepancy observations | 13, logged without masking AU failures |
| Same discrepant EQ instances/bands rendered | 5, all passed |
| Deliberate wrapper/Core Audio bypass faults | 7,000, all detected |
| Seven standard isolated EQ probes | Enabled ≈ +6 dB; bypass 0 dB |
| Individual shipping-effect matrix | 300 cases passed |
| Protected OFF/Basic/Pro final chains | 90 cases passed |
| Largest final sample peak | 0.8912472128868103, unchanged from baseline |

The same discrepant-band probes measured 5.999999992551065 dB when enabled
and 0 dB when deliberately bypassed. The enabled measurement did not rewrite
the target band's bypass value. These outcomes support the corrected audit
oracle rather than a retry-based claim of stability. `bash -n` for the runner
and `git diff --check` also passed. No shipping source changed for this task,
so an unrelated iOS rebuild was not used as evidence for this macOS assertion.

## Limits

This resolves the reproducible macOS audit false failure. Offline PCM checks
do not establish physical-device timing, thermal behavior or live iPhone audio
continuity. Those remain the existing device-validation items in ROADMAP.
