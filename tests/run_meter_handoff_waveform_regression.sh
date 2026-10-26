#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
combined_dir=$(mktemp -d /private/tmp/OngakuMeterHandoff.XXXXXX)
trap 'rm -rf "$combined_dir"' EXIT
python3 tests/extract_dsp_transition_fixture.py "$combined_dir/ShippingDSPTransition.swift"
python3 tests/extract_sinc_measurement_fixture.py "$combined_dir/ShippingSinc.swift"
python3 tests/extract_meter_handoff_fixture.py "$combined_dir/ShippingHRTF.swift"
source tests/spectral_transient_audit_support.sh
prepare_spectral_transient_audit "$combined_dir"
swiftc "${spectral_native_flags[@]}" -parse-as-library -O -suppress-warnings -module-cache-path "$combined_dir/module-cache" \
    audio/IntegratedLoudnessMeter.swift audio/EffectMeterObservation.swift audio/PlaybackHandoffClock.swift audio/ImpulseResponseCatalog.swift \
    audio/EffectTransitionPolicy.swift audio/AudioEffectPreset.swift audio/effects/*.swift tests/EffectAuditSupport.swift \
    "$combined_dir/ShippingDSPTransition.swift" "$combined_dir/ShippingSinc.swift" "$combined_dir/ShippingHRTF.swift" \
    tests/ReconstructedPeak.swift tests/ContinuousMeterHandoffRegression.swift tests/MeterHandoffWaveformRegression.swift -o "$combined_dir/combined"
"$combined_dir/combined" "$@"
if [[ $# -gt 0 ]] && [[ " ${*} " == *" --quick "* ]]; then exit 0; fi
if [[ $# -gt 0 ]] && [[ " ${*} " == *" --continuous "* ]]; then
    for fault in offset stamp mute limiter; do
        if "$combined_dir/combined" --continuous --quick "--continuous-${fault}-fixture" > "$combined_dir/continuous-${fault}.log" 2>&1; then
            echo "FAIL: continuous ${fault} escaped guards" >&2
            exit 1
        fi
        case "$fault" in
            offset) expected='Continuous source timeline mismatch' ;;
            stamp|mute) expected='Continuous processed reference mismatch|Continuous gain feedback mismatch' ;;
            limiter) expected='Overloaded safety output exceeds 0 dBFS' ;;
        esac
        rg -q "$expected" "$combined_dir/continuous-${fault}.log"
    done
    echo 'PASS: continuous feedback rejects source offset, delivery timestamps, muting and bypassed limiting'
    exit 0
fi
for fault in stale offset mute handoff; do
    if "$combined_dir/combined" --quick "--${fault}-fixture" > "$combined_dir/${fault}.log" 2>&1; then
        echo "FAIL: ${fault} escaped combined waveform guards" >&2
        exit 1
    fi
    rg -q 'Delayed meter handoff created a level dip|Delayed meter or timeline changed reference waveform|Delayed readings changed gain plan|Shared effect/gain changed during source handoff' "$combined_dir/${fault}.log"
done
echo 'PASS: combined waveforms reject stale meters, source offset, output muting and mid-handoff gain faults'
