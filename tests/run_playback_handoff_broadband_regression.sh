#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
handoff_broadband_dir=$(mktemp -d /private/tmp/OngakuHandoffBroadband.XXXXXX)
trap 'rm -rf "$handoff_broadband_dir"' EXIT
python3 tests/extract_sinc_measurement_fixture.py "$handoff_broadband_dir/ShippingSincMeasurement.swift"
source tests/spectral_transient_audit_support.sh
prepare_spectral_transient_audit "$handoff_broadband_dir"
swiftc "${spectral_native_flags[@]}" -parse-as-library -O -suppress-warnings -D EXTENDED_HANDOFF_MEASUREMENT \
    -module-cache-path "$handoff_broadband_dir/module-cache" \
    audio/AudioEffectPreset.swift audio/effects/*.swift tests/EffectAuditSupport.swift \
    audio/PlaybackHandoffClock.swift "$handoff_broadband_dir/ShippingSincMeasurement.swift" \
    tests/PlaybackHandoffWaveformRegression.swift tests/PlaybackHandoffBroadbandRegression.swift \
    -o "$handoff_broadband_dir/handoff-broadband"
"$handoff_broadband_dir/handoff-broadband"
if "$handoff_broadband_dir/handoff-broadband" --misaligned-fixture > "$handoff_broadband_dir/negative-control.log" 2>&1; then
    echo "FAIL: eight-frame broadband misalignment escaped waveform guards" >&2
    exit 1
fi
if ! rg -q 'Broadband alignment exceeds|Broadband waveform correlation/residual failed|Broadband fade energy changed' "$handoff_broadband_dir/negative-control.log"; then
    cat "$handoff_broadband_dir/negative-control.log" >&2
    exit 1
fi
echo "PASS: broadband guards reject an intentionally misaligned eight-frame replacement"
