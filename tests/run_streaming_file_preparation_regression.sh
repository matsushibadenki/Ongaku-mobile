#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
streaming_test_dir=$(mktemp -d /private/tmp/OngakuStreaming.XXXXXX)
trap 'rm -rf "$streaming_test_dir"' EXIT
swiftc -parse-as-library -O -module-cache-path "$streaming_test_dir/module-cache" \
    audio/StreamingAudioFilePreparation.swift tests/StreamingFilePreparationRegression.swift \
    -o "$streaming_test_dir/streaming-tests"
"$streaming_test_dir/streaming-tests"
