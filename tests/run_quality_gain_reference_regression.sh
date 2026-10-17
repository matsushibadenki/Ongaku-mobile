#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
quality_dir=$(mktemp -d /private/tmp/OngakuQualityGain.XXXXXX)
trap 'rm -rf "$quality_dir"' EXIT
python3 tests/extract_dsp_transition_fixture.py "$quality_dir/ShippingDSPTransition.swift"
swiftc -parse-as-library -O -suppress-warnings -module-cache-path "$quality_dir/cache" \
 audio/IntegratedLoudnessMeter.swift audio/EffectMeterObservation.swift audio/EffectTransitionPolicy.swift \
 audio/AudioEffectPreset.swift audio/effects/*.swift tests/EffectAuditSupport.swift \
 "$quality_dir/ShippingDSPTransition.swift" tests/QualityGainReferenceRegression.swift -o "$quality_dir/quality"
"$quality_dir/quality"
if "$quality_dir/quality" --replace-reference > "$quality_dir/negative.log" 2>&1; then
 echo 'FAIL: changed reference escaped guard'; exit 1
fi
rg -q 'same-track analysis changed input gain' "$quality_dir/negative.log"
echo 'PASS: reference guard rejects gain changes caused by late analysis'
