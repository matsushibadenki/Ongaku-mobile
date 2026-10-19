#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
audit_dir=$(mktemp -d /private/tmp/OngakuEffectLatency.XXXXXX)
trap 'rm -rf "$audit_dir"' EXIT
python3 tests/extract_dsp_transition_fixture.py "$audit_dir/Transition.swift"
swiftc -parse-as-library -O -suppress-warnings -module-cache-path "$audit_dir/cache" \
 audio/IntegratedLoudnessMeter.swift audio/EffectMeterObservation.swift audio/EffectTransitionPolicy.swift \
 audio/AudioEffectPreset.swift audio/effects/*.swift tests/EffectAuditSupport.swift \
 "$audit_dir/Transition.swift" tests/EffectLatencyStateRegression.swift -o "$audit_dir/check"
"$audit_dir/check"
