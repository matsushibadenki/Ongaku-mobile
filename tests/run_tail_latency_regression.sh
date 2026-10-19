#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
tail_dir=$(mktemp -d /private/tmp/OngakuTail.XXXXXX)
trap 'rm -rf "$tail_dir"' EXIT
effect_sources=(audio/AudioEffectPreset.swift audio/EffectTransitionPolicy.swift audio/effects/*.swift)
if [[ "${1:-}" == "--desktop" ]]; then
 desktop_root="${ONGAKU_DESKTOP_ROOT:-../Ongaku-desktop}/Sources/OngakuDesktop"
 effect_sources=("$desktop_root/AudioEffectPreset.swift" "$desktop_root/EffectTransitionPolicy.swift"
  "$desktop_root/AudioEffectNode.swift" "$desktop_root/AudioEffectModuleRegistry.swift" "$desktop_root/"*AudioEffect.swift)
fi
swiftc -parse-as-library -O -suppress-warnings -module-cache-path "$tail_dir/cache" \
 "${effect_sources[@]}" \
 tests/EffectAuditSupport.swift tests/TailLatencyRegression.swift -o "$tail_dir/tail"
"$tail_dir/tail"
if "$tail_dir/tail" --cut-tail > "$tail_dir/negative.log" 2>&1; then
 echo 'FAIL: immediate tail reset escaped detection' >&2; exit 1
fi
rg -q 'Tail was abruptly cut' "$tail_dir/negative.log" || { cat "$tail_dir/negative.log"; exit 1; }
echo 'PASS: rejected abrupt-tail negative control'
