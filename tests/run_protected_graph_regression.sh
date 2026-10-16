#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
graph_dir=$(mktemp -d /private/tmp/OngakuProtectedGraph.XXXXXX)
trap 'rm -rf "$graph_dir"' EXIT
xcrun clang++ -std=c++20 -O2 -fobjc-arc -fblocks -c audio/TruePeakAudioUnit.mm -o "$graph_dir/TruePeak.o"
swiftc -parse-as-library -O -import-objc-header audio/TruePeakAudioUnit.h "$graph_dir/TruePeak.o" -lc++ \
 -module-cache-path "$graph_dir/module-cache" audio/AudioEffectPreset.swift audio/effects/*.swift \
 tests/EffectAuditSupport.swift tests/ReconstructedPeak.swift tests/ProtectedGraphRegression.swift -o "$graph_dir/test"
"$graph_dir/test"
