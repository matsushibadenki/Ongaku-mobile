#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
resilience_dir=$(mktemp -d /private/tmp/OngakuRemoteResilience.XXXXXX)
trap 'rm -rf "$resilience_dir"' EXIT
swiftc -parse-as-library -g -module-cache-path "$resilience_dir/module-cache" \
 audio/RemoteAudioReadiness.swift audio/RemoteAudioHTTP.swift audio/RemoteAudioByteSource.swift \
 audio/RemoteAudioCache.swift audio/GoogleDriveAudioSource.swift tests/RemoteResilienceRegression.swift -o "$resilience_dir/test"
"$resilience_dir/test"
