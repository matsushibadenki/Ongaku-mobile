#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $# != 2 ]]; then echo 'usage: run_crest_output_peak_audit.sh fixtures output' >&2; exit 2; fi
fixtures="$1";out="$2";work=$(mktemp -d /private/tmp/OngakuCrestCompile.XXXXXX)
trap 'rm -rf "$work"' EXIT
mkdir -p "$out/mobile" "$out/desktop"
desktop="${ONGAKU_DESKTOP_ROOT:-../Ongaku-desktop}/Sources/OngakuDesktop"
python3 tests/extract_mobile_peak_gain_policy.py "$work/ExtractedGain.swift"
python3 tests/extract_desktop_crossfade_policy.py "$desktop/PlaybackController.swift" "$work/CrossfadePolicy.swift"
xcrun clang++ -std=c++20 -O2 -fobjc-arc -fblocks -c audio/TruePeakAudioUnit.mm -o "$work/TruePeak.o"
source tests/spectral_transient_audit_support.sh
prepare_spectral_transient_audit "$work"
cmp audio/AudioProcessingPolicy.swift "$desktop/AudioProcessingPolicy.swift"
swiftc "${spectral_native_flags[@]}" -parse-as-library -O -suppress-warnings "$work/TruePeak.o" -lc++ -module-cache-path "$work/cache" audio/AudioProcessingPolicy.swift audio/IntegratedLoudnessMeter.swift audio/AudioEffectPreset.swift audio/effects/*.swift "$work/ExtractedGain.swift" tests/EffectAuditSupport.swift tests/CrestOutputPeakAudit.swift -o "$work/mobile"
"$work/mobile" "$fixtures" "$out/mobile" | tee "$out/mobile.log"
swiftc "${spectral_native_flags[@]}" -parse-as-library -O -suppress-warnings -D DESKTOP_FULL_PEAK_AUDIT "$work/TruePeak.o" -lc++ -module-cache-path "$work/cache" "$desktop/AudioProcessingPolicy.swift" "$desktop/AudioEffectPreset.swift" "$desktop/AudioEffectNode.swift" "$desktop/AudioEffectModuleRegistry.swift" "$desktop/"*AudioEffect.swift "$desktop/FinalOutputProtection.swift" "$work/CrossfadePolicy.swift" tests/EffectAuditSupport.swift tests/CrestOutputPeakAudit.swift -o "$work/desktop"
"$work/desktop" "$fixtures" "$out/desktop" | tee "$out/desktop.log"
OPENBLAS_NUM_THREADS=1 python3 tests/analyze_crest_output_peaks.py "$out" | tee "$out/analysis.log"
