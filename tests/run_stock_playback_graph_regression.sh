#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
stock_test_dir=$(mktemp -d /private/tmp/OngakuStockGraph.XXXXXX)
source tests/spectral_transient_audit_support.sh
prepare_spectral_transient_audit "$stock_test_dir"
swiftc "${spectral_native_flags[@]}" -O -module-cache-path "$stock_test_dir/module-cache" \
    audio/AudioEffectPreset.swift audio/effects/*.swift tests/EffectAuditSupport.swift \
    tests/StockPlaybackGraphRegression.swift -o "$stock_test_dir/stock-graph-tests"
"$stock_test_dir/stock-graph-tests"
