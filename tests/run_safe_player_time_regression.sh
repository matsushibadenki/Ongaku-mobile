#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
clock_test_dir=$(mktemp -d /private/tmp/OngakuPlayerClock.XXXXXX)
trap 'rm -rf "$clock_test_dir"' EXIT
desktop_root="${ONGAKU_DESKTOP_ROOT:-../Ongaku-desktop}"
cmp audio/TruePeakAudioUnit.h "$desktop_root/Sources/OngakuAudioDSP/include/TruePeakAudioUnit.h"
cmp audio/TruePeakAudioUnit.mm "$desktop_root/Sources/OngakuAudioDSP/TruePeakAudioUnit.mm"
xcrun clang++ -std=c++20 -O2 -fobjc-arc tests/SafePlayerTimeRegression.mm audio/TruePeakAudioUnit.mm \
  -framework AVFoundation -framework AudioToolbox -framework Foundation -o "$clock_test_dir/test"
"$clock_test_dir/test"
