#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
meter_test_dir=$(mktemp -d /private/tmp/OngakuMeterDelivery.XXXXXX)
trap 'rm -rf "$meter_test_dir"' EXIT
python3 tests/extract_dsp_transition_fixture.py "$meter_test_dir/ShippingDSPTransition.swift"
swiftc -parse-as-library -O -suppress-warnings -module-cache-path "$meter_test_dir/module-cache" \
    audio/IntegratedLoudnessMeter.swift audio/EffectMeterObservation.swift audio/AudioEffectPreset.swift audio/effects/*.swift \
    tests/EffectAuditSupport.swift "$meter_test_dir/ShippingDSPTransition.swift" \
    tests/MeterDeliveryRegression.swift -o "$meter_test_dir/meter-delivery"
"$meter_test_dir/meter-delivery"
if "$meter_test_dir/meter-delivery" --stale-fixture > "$meter_test_dir/stale.log" 2>&1; then
    echo 'FAIL: stale meter fault escaped detection' >&2
    exit 1
fi
rg -q 'Expired measurement reused' "$meter_test_dir/stale.log"
echo 'PASS: deliberately bypassing measurement freshness fails the regression guard'
