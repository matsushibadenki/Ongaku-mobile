#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
unit_dir=$(mktemp -d /private/tmp/OngakuTruePeakUnit.XXXXXX)
trap 'rm -rf "$unit_dir"' EXIT
unit_flags=()
if [[ "${TRUE_PEAK_SANITIZERS:-0}" == "1" ]]; then unit_flags=(-fsanitize=address,undefined -fno-omit-frame-pointer); fi
xcrun clang++ -std=c++20 -O2 ${unit_flags[@]+"${unit_flags[@]}"} tests/TruePeakDSPTests.cpp -o "$unit_dir/dsp"
"$unit_dir/dsp"
xcrun clang++ -std=c++20 -O2 -fobjc-arc -fblocks ${unit_flags[@]+"${unit_flags[@]}"} \
 -framework AVFoundation -framework AudioToolbox -framework Foundation \
 audio/TruePeakAudioUnit.mm tests/TruePeakAudioUnitTests.mm -o "$unit_dir/au"
"$unit_dir/au"
