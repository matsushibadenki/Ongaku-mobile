#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
graph_dir=$(mktemp -d /private/tmp/OngakuProtectedGraph.XXXXXX)
trap 'rm -rf "$graph_dir"' EXIT
xcrun clang++ -std=c++20 -O2 -fobjc-arc -fblocks -c audio/TruePeakAudioUnit.mm -o "$graph_dir/TruePeak.o"
source tests/spectral_transient_audit_support.sh
prepare_spectral_transient_audit "$graph_dir"
swiftc "${spectral_native_flags[@]}" -parse-as-library -O  "$graph_dir/TruePeak.o" -lc++ \
 -module-cache-path "$graph_dir/module-cache" audio/AudioEffectPreset.swift audio/effects/*.swift \
 tests/EffectAuditSupport.swift tests/ReconstructedPeak.swift tests/ProtectedGraphRegression.swift -o "$graph_dir/test"
"$graph_dir/test" "$@"
