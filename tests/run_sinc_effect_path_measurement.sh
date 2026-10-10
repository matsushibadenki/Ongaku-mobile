#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
sinc_test_dir=$(mktemp -d /private/tmp/OngakuSincMeasurement.XXXXXX)
trap 'rm -rf "$sinc_test_dir"' EXIT
python3 tests/extract_sinc_measurement_fixture.py "$sinc_test_dir/ShippingSincMeasurement.swift"
swiftc -parse-as-library -O -suppress-warnings -D EXTENDED_SOURCE_MEASUREMENT \
    -module-cache-path "$sinc_test_dir/module-cache" \
    audio/AudioEffectPreset.swift audio/effects/*.swift tests/EffectAuditSupport.swift \
    "$sinc_test_dir/ShippingSincMeasurement.swift" tests/SourcePathConversionRegression.swift \
    tests/SincEffectPathMeasurement.swift -o "$sinc_test_dir/sinc-measurement"
"$sinc_test_dir/sinc-measurement"
