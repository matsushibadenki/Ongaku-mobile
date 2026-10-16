#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
readiness_dir=$(mktemp -d /private/tmp/OngakuReadiness.XXXXXX)
trap 'rm -rf "$readiness_dir"' EXIT
swiftc -parse-as-library -O -module-cache-path "$readiness_dir/module-cache" \
 audio/RemoteAudioReadiness.swift audio/RemoteAudioByteSource.swift tests/RemoteReadinessRegression.swift -o "$readiness_dir/test"
"$readiness_dir/test"
