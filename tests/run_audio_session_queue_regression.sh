#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
session_test_dir=$(mktemp -d /private/tmp/OngakuSessionQueue.XXXXXX)
swiftc -O -module-cache-path "$session_test_dir/module-cache" \
    audio/PlaybackAudioSession.swift tests/AudioSessionQueueRegression.swift \
    -o "$session_test_dir/session-tests"
"$session_test_dir/session-tests"
