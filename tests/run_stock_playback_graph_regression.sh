#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
stock_test_dir=$(mktemp -d /private/tmp/OngakuStockGraph.XXXXXX)
swiftc -O -module-cache-path "$stock_test_dir/module-cache" \
    audio/AudioEffectPreset.swift audio/effects/*.swift tests/EffectAuditSupport.swift \
    tests/StockPlaybackGraphRegression.swift -o "$stock_test_dir/stock-graph-tests"
"$stock_test_dir/stock-graph-tests"
