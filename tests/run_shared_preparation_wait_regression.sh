#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
shared_wait_dir=$(mktemp -d /private/tmp/OngakuSharedWait.XXXXXX)
trap 'rm -rf "$shared_wait_dir"' EXIT
python3 tests/extract_shared_preparation_wait.py "$shared_wait_dir/Fixture.swift"
swiftc -parse-as-library -O -module-cache-path "$shared_wait_dir/cache" "$shared_wait_dir/Fixture.swift" tests/SharedPreparationWaitRegression.swift -o "$shared_wait_dir/check"
"$shared_wait_dir/check"
