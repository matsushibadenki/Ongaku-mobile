#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
audit_dir=$(mktemp -d /private/tmp/OngakuGraphReuseState.XXXXXX)
trap 'rm -rf "$audit_dir"' EXIT
effect_sources=(audio/AudioEffectPreset.swift audio/EffectTransitionPolicy.swift audio/effects/*.swift)
unit_root="$PWD/audio"; header_root="$unit_root"
if [[ "${1:-}" == --desktop ]]; then
 desktop_root="${ONGAKU_DESKTOP_ROOT:-../Ongaku-desktop}/Sources/OngakuDesktop"
 effect_sources=("$desktop_root/AudioEffectPreset.swift" "$desktop_root/EffectTransitionPolicy.swift"
  "$desktop_root/AudioEffectNode.swift" "$desktop_root/AudioEffectModuleRegistry.swift" "$desktop_root/"*AudioEffect.swift)
 unit_root="${ONGAKU_DESKTOP_ROOT:-../Ongaku-desktop}/Sources/OngakuAudioDSP"; header_root="$unit_root/include"
fi
for unit in GainEnvelope TruePeak; do
 xcrun clang++ -std=c++20 -O2 -fobjc-arc -fblocks -I "$header_root" -c "$unit_root/${unit}AudioUnit.mm" -o "$audit_dir/$unit.o"
done
source tests/spectral_transient_audit_support.sh
prepare_spectral_transient_audit "$audit_dir"
swiftc "${spectral_native_flags[@]}" -parse-as-library -O -suppress-warnings -module-cache-path "$audit_dir/cache" \
  "${effect_sources[@]}" \
 audio/AudioProcessingPolicy.swift audio/AudioThreadGainStage.swift tests/EffectAuditSupport.swift \
 tests/GraphReuseStateRegression.swift "$audit_dir/"*.o -Xlinker -lc++ -o "$audit_dir/reuse"
"$audit_dir/reuse"
if "$audit_dir/reuse" --skip-reset > "$audit_dir/negative.log" 2>&1; then
 echo 'FAIL: retained-history negative control escaped detection'; exit 1
fi
rg -q 'retired track history survived graph reuse' "$audit_dir/negative.log" || { cat "$audit_dir/negative.log"; exit 1; }
echo 'PASS: rejected missing full-state reset negative control'
