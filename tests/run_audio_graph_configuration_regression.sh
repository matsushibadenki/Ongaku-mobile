#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
audit_dir=$(mktemp -d /private/tmp/OngakuGraphKey.XXXXXX)
trap 'rm -rf "$audit_dir"' EXIT
swiftc -parse-as-library -O -module-cache-path "$audit_dir/cache" audio/AudioProcessingPolicy.swift tests/AudioGraphConfigurationRegression.swift -o "$audit_dir/key"
"$audit_dir/key"
