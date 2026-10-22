#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
sourceinfo_dir=$(mktemp -d /private/tmp/OngakuSourceInfo.XXXXXX)
trap 'rm -rf "$sourceinfo_dir"' EXIT
swiftc -parse-as-library -O -module-cache-path "$sourceinfo_dir/cache" \
 audio/AudioSourceFileInfo.swift tests/AudioSourceFileInfoRegression.swift -o "$sourceinfo_dir/test"
"$sourceinfo_dir/test"
