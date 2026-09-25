#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
transport_test_dir=$(mktemp -d /private/tmp/OngakuTransport.XXXXXX)
swiftc -O -module-cache-path "$transport_test_dir/module-cache" \
    audio/PlaybackTransportPolicy.swift tests/PlaybackTransportRegression.swift \
    -o "$transport_test_dir/transport-regression"
"$transport_test_dir/transport-regression"
