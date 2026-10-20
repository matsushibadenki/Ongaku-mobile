#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
vu_dir=$(mktemp -d /private/tmp/OngakuVU.XXXXXX)
trap 'rm -rf "$vu_dir"' EXIT
swiftc -parse-as-library -O -module-cache-path "$vu_dir/cache" \
 audio/Ballistics.swift tests/VUMeterResponseRegression.swift -o "$vu_dir/test"
"$vu_dir/test"
