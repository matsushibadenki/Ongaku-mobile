#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
desktop_root="${ONGAKU_DESKTOP_ROOT:-../Ongaku-desktop}"
# Keep the independent repositories buildable, and fail on any DSP drift.
for name in TruePeakDSP.hpp TruePeakAudioUnit.mm; do
 cmp "audio/$name" "$desktop_root/Sources/OngakuAudioDSP/$name"
done
cmp audio/TruePeakAudioUnit.h "$desktop_root/Sources/OngakuAudioDSP/include/TruePeakAudioUnit.h"
audit_dir=$(mktemp -d /private/tmp/OngakuDesktopTruePeak.XXXXXX)
trap 'rm -rf "$audit_dir"' EXIT
xcrun clang++ -std=c++20 -O2 -fobjc-arc -fblocks -I "$desktop_root/Sources/OngakuAudioDSP/include" \
 -c "$desktop_root/Sources/OngakuAudioDSP/TruePeakAudioUnit.mm" -o "$audit_dir/TruePeak.o"
case "${1:-}" in
 --handoff) shift; audit_source=tests/ProtectedGraphRegression.swift ;;
 *) audit_source=tests/FinalOutputPeakRegression.swift ;;
esac
swiftc -parse-as-library -O -D DESKTOP_FULL_PEAK_AUDIT \
 -import-objc-header "$desktop_root/Sources/OngakuAudioDSP/include/TruePeakAudioUnit.h" \
 "$audit_dir/TruePeak.o" -lc++ -module-cache-path "$audit_dir/module-cache" \
 "$desktop_root/Sources/OngakuDesktop/AudioEffectPreset.swift" \
 "$desktop_root/Sources/OngakuDesktop/AudioEffectNode.swift" \
 "$desktop_root/Sources/OngakuDesktop/AudioEffectModuleRegistry.swift" \
 "$desktop_root/Sources/OngakuDesktop/"*AudioEffect.swift \
 "$desktop_root/Sources/OngakuDesktop/FinalOutputProtection.swift" \
 tests/EffectAuditSupport.swift tests/ReconstructedPeak.swift "$audit_source" -o "$audit_dir/test"
"$audit_dir/test" "$@"
