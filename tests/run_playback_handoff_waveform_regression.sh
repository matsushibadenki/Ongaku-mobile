#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
handoff_wave_dir=$(mktemp -d /private/tmp/OngakuHandoffWaveform.XXXXXX)
trap 'rm -rf "$handoff_wave_dir"' EXIT
python3 tests/extract_sinc_measurement_fixture.py "$handoff_wave_dir/ShippingSincMeasurement.swift"
source tests/spectral_transient_audit_support.sh
prepare_spectral_transient_audit "$handoff_wave_dir"
swiftc "${spectral_native_flags[@]}" -parse-as-library -O -suppress-warnings \
    -module-cache-path "$handoff_wave_dir/module-cache" \
    audio/AudioEffectPreset.swift audio/effects/*.swift tests/EffectAuditSupport.swift \
    audio/PlaybackHandoffClock.swift "$handoff_wave_dir/ShippingSincMeasurement.swift" \
    tests/PlaybackHandoffWaveformRegression.swift \
    -o "$handoff_wave_dir/handoff-waveform"
"$handoff_wave_dir/handoff-waveform"

if "$handoff_wave_dir/handoff-waveform" --misaligned-fixture > "$handoff_wave_dir/negative-control.log" 2>&1; then
    echo "FAIL: eight-frame misalignment escaped waveform guards" >&2
    exit 1
fi
if ! rg -q 'Scheduled phase exceeds|Phase cancellation in handoff|Scheduled waveform misalignment' "$handoff_wave_dir/negative-control.log"; then
    cat "$handoff_wave_dir/negative-control.log" >&2
    exit 1
fi
echo "PASS: waveform guards reject an intentionally misaligned eight-frame replacement"
