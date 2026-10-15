#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
spatial_test_dir=$(mktemp -d /private/tmp/OngakuSpatial.XXXXXX)
trap 'rm -rf "$spatial_test_dir"' EXIT
python3 tests/extract_spatial_transition_fixture.py "$spatial_test_dir/ShippingSpatial.swift"
swiftc -parse-as-library -O -suppress-warnings -module-cache-path "$spatial_test_dir/module-cache" \
    audio/PlaybackHandoffClock.swift audio/AudioPreparationCancellation.swift audio/ImpulseResponseCatalog.swift \
    "$spatial_test_dir/ShippingSpatial.swift" tests/SpatialTransitionStateRegression.swift \
    tests/SpatialTransitionWaveformRegression.swift -o "$spatial_test_dir/spatial-regression"
"$spatial_test_dir/spatial-regression" "$@"
if [[ $# -gt 0 ]] && [[ " ${*} " == *" --state-only "* ]]; then exit 0; fi
for fault in misaligned mute; do
    if "$spatial_test_dir/spatial-regression" "--${fault}-fixture" > "$spatial_test_dir/${fault}.log" 2>&1; then
        echo "FAIL: spatial ${fault} fault escaped guards" >&2
        exit 1
    fi
    if ! rg -q 'Spatial replacement timeline mismatch|Spatial transition created a silent PCM window' "$spatial_test_dir/${fault}.log"; then
        cat "$spatial_test_dir/${fault}.log" >&2
        exit 1
    fi
done
echo "PASS: spatial guards reject an eight-frame offset and deliberate output muting"
