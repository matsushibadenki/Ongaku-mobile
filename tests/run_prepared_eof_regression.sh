#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
audit_dir=$(mktemp -d /private/tmp/OngakuPreparedEOF.XXXXXX)
trap 'rm -rf "$audit_dir"' EXIT
python3 tests/extract_prepared_eof_fixture.py "$audit_dir/fixture.swift"
swiftc -parse-as-library -O -module-cache-path "$audit_dir/cache" "$audit_dir/fixture.swift" tests/PreparedEOFRegression.swift -o "$audit_dir/audit"
"$audit_dir/audit"
python3 tests/extract_prepared_eof_fixture.py "$audit_dir/fixture.swift" --global-token
swiftc -parse-as-library -O -module-cache-path "$audit_dir/cache" "$audit_dir/fixture.swift" tests/PreparedEOFRegression.swift -o "$audit_dir/negative"
if "$audit_dir/negative" > "$audit_dir/negative.log" 2>&1; then
 echo 'FAIL: global callback token regression accepted'; exit 1
fi
rg -q 'rejected handoff invalidated audible prepared EOF' "$audit_dir/negative.log"
echo 'PASS: negative control rejects the original global handoff callback token'
