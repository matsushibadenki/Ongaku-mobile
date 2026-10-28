#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $# != 2 ]]; then echo 'usage: run_product_output_peak_audit.sh fixtures output' >&2; exit 2; fi
fixtures="$1"; out="$2"; work=$(mktemp -d /private/tmp/OngakuProductPeakCompile.XXXXXX)
trap 'rm -rf "$work"' EXIT
mkdir -p "$out/mobile" "$out/desktop"
python3 tests/extract_mobile_peak_gain_policy.py "$work/ExtractedGain.swift"
xcrun clang++ -std=c++20 -O2 -fobjc-arc -fblocks -c audio/TruePeakAudioUnit.mm -o "$work/TruePeak.o"
source tests/spectral_transient_audit_support.sh
prepare_spectral_transient_audit "$work"
for name in TruePeakDSP.hpp TruePeakAudioUnit.mm; do cmp "audio/$name" "${ONGAKU_DESKTOP_ROOT:-../Ongaku-desktop}/Sources/OngakuAudioDSP/$name"; done
cmp audio/AudioProcessingPolicy.swift "${ONGAKU_DESKTOP_ROOT:-../Ongaku-desktop}/Sources/OngakuDesktop/AudioProcessingPolicy.swift"
cmp audio/TruePeakAudioUnit.h "${ONGAKU_DESKTOP_ROOT:-../Ongaku-desktop}/Sources/OngakuAudioDSP/include/TruePeakAudioUnit.h"
swiftc "${spectral_native_flags[@]}" -parse-as-library -O -suppress-warnings "$work/TruePeak.o" -lc++ -module-cache-path "$work/cache" audio/AudioProcessingPolicy.swift audio/IntegratedLoudnessMeter.swift audio/AudioEffectPreset.swift audio/effects/*.swift "$work/ExtractedGain.swift" tests/EffectAuditSupport.swift tests/ProductOutputPeakAudit.swift -o "$work/mobile"
"$work/mobile" "$fixtures" "$out/mobile" | tee "$out/mobile.log"
desktop="${ONGAKU_DESKTOP_ROOT:-../Ongaku-desktop}/Sources/OngakuDesktop"
swiftc "${spectral_native_flags[@]}" -parse-as-library -O -suppress-warnings -D DESKTOP_FULL_PEAK_AUDIT "$work/TruePeak.o" -lc++ -module-cache-path "$work/cache" "$desktop/AudioProcessingPolicy.swift" "$desktop/AudioEffectPreset.swift" "$desktop/AudioEffectNode.swift" "$desktop/AudioEffectModuleRegistry.swift" "$desktop/"*AudioEffect.swift "$desktop/FinalOutputProtection.swift" tests/EffectAuditSupport.swift tests/ProductOutputPeakAudit.swift -o "$work/desktop"
"$work/desktop" "$fixtures" "$out/desktop" | tee "$out/desktop.log"
OPENBLAS_NUM_THREADS=1 python3 tests/analyze_product_output_peaks.py "$out" | tee "$out/analysis.log"
