#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
effect_presentation_dir=$(mktemp -d /private/tmp/OngakuEffectPresentation.XXXXXX)
trap 'rm -rf "$effect_presentation_dir"' EXIT
python3 tests/extract_effect_presentation_fixture.py "$effect_presentation_dir/ShippingPresentation.swift"
swiftc -parse-as-library -O -module-cache-path "$effect_presentation_dir/cache" \
    "$effect_presentation_dir/ShippingPresentation.swift" tests/EffectPresentationRegression.swift -o "$effect_presentation_dir/check"
"$effect_presentation_dir/check"
