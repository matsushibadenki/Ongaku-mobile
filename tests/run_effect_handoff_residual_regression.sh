#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
audit_dir=$(mktemp -d /private/tmp/OngakuEffectHandoff.XXXXXX)
trap 'rm -rf "$audit_dir"' EXIT
python3 tests/extract_sinc_measurement_fixture.py "$audit_dir/Sinc.swift"
swiftc -parse-as-library -O -suppress-warnings -D EXTENDED_HANDOFF_MEASUREMENT \
 -module-cache-path "$audit_dir/cache" audio/AudioEffectPreset.swift audio/effects/*.swift \
 tests/EffectAuditSupport.swift audio/PlaybackHandoffClock.swift "$audit_dir/Sinc.swift" \
 tests/PlaybackHandoffWaveformRegression.swift tests/EffectHandoffResidualRegression.swift -o "$audit_dir/handoff"
"$audit_dir/handoff"
if "$audit_dir/handoff" --reset-rack > "$audit_dir/negative.log" 2>&1; then
 echo 'FAIL: shared rack reset escaped residual checks' >&2; exit 1
fi
rg -q 'Shared rack residual failed|Handoff changed effect level' "$audit_dir/negative.log" || { cat "$audit_dir/negative.log"; exit 1; }
echo 'PASS: rejected shared-rack reset negative control'
