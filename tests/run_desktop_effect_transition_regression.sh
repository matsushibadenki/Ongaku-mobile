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
cmp audio/EffectTransitionPolicy.swift "$desktop_root/Sources/OngakuDesktop/EffectTransitionPolicy.swift"
python3 tests/extract_desktop_effect_transition_fixture.py "$audit_dir/ShippingDesktopEffectTransition.swift" "$desktop_root"
swiftc -parse-as-library -O -D DESKTOP_FULL_PEAK_AUDIT \
 -import-objc-header "$desktop_root/Sources/OngakuAudioDSP/include/TruePeakAudioUnit.h" \
 "$audit_dir/TruePeak.o" -lc++ -module-cache-path "$audit_dir/module-cache" \
 "$desktop_root/Sources/OngakuDesktop/AudioEffectPreset.swift" \
 "$desktop_root/Sources/OngakuDesktop/AudioEffectNode.swift" \
 "$desktop_root/Sources/OngakuDesktop/AudioEffectModuleRegistry.swift" \
 "$desktop_root/Sources/OngakuDesktop/"*AudioEffect.swift \
 "$desktop_root/Sources/OngakuDesktop/FinalOutputProtection.swift" \
 "$desktop_root/Sources/OngakuDesktop/EffectTransitionPolicy.swift" \
 "$desktop_root/Sources/OngakuDesktop/EffectParameterTransition.swift" \
 "$audit_dir/ShippingDesktopEffectTransition.swift" \
 tests/EffectAuditSupport.swift tests/ReconstructedPeak.swift tests/DesktopEffectTransitionRegression.swift -o "$audit_dir/test"
"$audit_dir/test" "$@"

for defect in unprotected mute unsafe-bypass; do
 if "$audit_dir/test" "--$defect-fixture" > "$audit_dir/$defect.log" 2>&1; then
  echo "FAIL: $defect defect escaped continuity checks" >&2; exit 1
 fi
 case "$defect" in
  unprotected) expected='Continuous update bypassed interpolation' ;;
  mute) expected='Continuous controls changed output envelope' ;;
  unsafe-bypass) expected='Audible bypass committed without zero-gain protection' ;;
 esac
 rg -q "$expected" "$audit_dir/$defect.log" || { cat "$audit_dir/$defect.log"; exit 1; }
 echo "PASS: rejected $defect continuity defect"
done
