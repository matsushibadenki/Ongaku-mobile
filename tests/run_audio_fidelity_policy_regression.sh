#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
fidelity_dir=$(mktemp -d /private/tmp/OngakuFidelity.XXXXXX)
trap 'rm -rf "$fidelity_dir"' EXIT
swiftc -parse-as-library -O -module-cache-path "$fidelity_dir/cache" \
 audio/AudioOutputPolicy.swift audio/AudioProcessingPolicy.swift audio/IntegratedLoudnessMeter.swift \
 tests/AudioFidelityPolicyRegression.swift -o "$fidelity_dir/test"
"$fidelity_dir/test" "$fidelity_dir/pcm"
python3 tests/verify_loudness_meter.py "$fidelity_dir/pcm"
