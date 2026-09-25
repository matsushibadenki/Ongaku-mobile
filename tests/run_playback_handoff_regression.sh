#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
handoff_test_dir=$(mktemp -d /private/tmp/OngakuHandoff.XXXXXX)
swiftc -O -module-cache-path "$handoff_test_dir/module-cache" \
    audio/PlaybackHandoffClock.swift tests/PlaybackHandoffRegression.swift \
    -o "$handoff_test_dir/handoff-regression"
"$handoff_test_dir/handoff-regression"
