#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
audit_dir=$(mktemp -d /private/tmp/OngakuRecoveredEnd.XXXXXX)
trap 'rm -rf "$audit_dir"' EXIT
python3 tests/extract_transport_continuity_fixture.py "$audit_dir/Transport.swift"
python3 tests/extract_recovered_track_end_fixture.py "$audit_dir/Queue.swift"
swiftc -parse-as-library -O -module-cache-path "$audit_dir/cache" \
 audio/EffectTransitionPolicy.swift "$audit_dir/Transport.swift" "$audit_dir/Queue.swift" \
 tests/RecoveredTrackEndRegression.swift -o "$audit_dir/audit"
"$audit_dir/audit"

if "$audit_dir/audit" --stranded-seek-fixture > "$audit_dir/negative.log" 2>&1; then
 echo 'FAIL: stranded seek escaped recovered EOF checks'; exit 1
fi
rg -q 'explicit resume stranded EOF behind a cancelled seek' "$audit_dir/negative.log"
echo 'PASS: negative control rejects the original stranded-seek state'
