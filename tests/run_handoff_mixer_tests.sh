#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mixer_test_dir=$(mktemp -d /private/tmp/OngakuHandoffMixer.XXXXXX)
sanitizer_flags=()
if [[ "${HANDOFF_SANITIZERS:-0}" == "1" ]]; then
    sanitizer_flags=(-fsanitize=address,undefined -fno-omit-frame-pointer)
fi
xcrun clang++ -std=c++20 -O2 -fobjc-arc -fblocks "${sanitizer_flags[@]}" \
    -framework AVFoundation -framework AudioToolbox -framework Foundation \
    audio/HandoffMixerAudioUnit.mm tests/HandoffMixerRenderTests.mm \
    -o "$mixer_test_dir/mixer-tests"
"$mixer_test_dir/mixer-tests"
xcrun clang++ -std=c++20 -O2 "${sanitizer_flags[@]}" tests/HandoffEnvelopeConcurrency.cpp \
    -o "$mixer_test_dir/concurrency-tests"
"$mixer_test_dir/concurrency-tests"
