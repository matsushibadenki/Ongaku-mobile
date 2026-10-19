#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
fixture_dir=$(mktemp -d /private/tmp/OngakuForeground.XXXXXX)
trap 'rm -rf "$fixture_dir"' EXIT
python3 tests/extract_foreground_recovery_fixture.py "$fixture_dir/fixture.swift"
swiftc -module-cache-path "$fixture_dir/cache" audio/PlaybackTransportPolicy.swift \
 "$fixture_dir/fixture.swift" tests/ForegroundRecoveryRegression.swift -o "$fixture_dir/audit"
"$fixture_dir/audit"
python3 tests/extract_foreground_recovery_fixture.py "$fixture_dir/fixture.swift" --refresh-first
swiftc -module-cache-path "$fixture_dir/cache" audio/PlaybackTransportPolicy.swift \
 "$fixture_dir/fixture.swift" tests/ForegroundRecoveryRegression.swift -o "$fixture_dir/negative"
if "$fixture_dir/negative" > "$fixture_dir/negative.log" 2>&1; then
 echo 'FAIL: refresh-first regression was accepted'; exit 1
fi
rg -q 'foreground erased playback intent' "$fixture_dir/negative.log"
echo 'PASS: negative control rejects refresh before intent capture'
