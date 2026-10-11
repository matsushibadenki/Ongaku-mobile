#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
render_health_test_dir=$(mktemp -d /private/tmp/OngakuRenderHealth.XXXXXX)
swiftc -O -module-cache-path "$render_health_test_dir/module-cache" \
    audio/AudioRenderHealthMonitor.swift audio/AudioRenderHeartbeat.swift \
    tests/RenderHealthRegression.swift -o "$render_health_test_dir/render-health-regression"
"$render_health_test_dir/render-health-regression"
