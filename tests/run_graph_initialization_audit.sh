#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
audit_dir=$(mktemp -d /private/tmp/OngakuGraphInitialization.XXXXXX)
trap 'rm -rf "$audit_dir"' EXIT
effect_sources=(audio/AudioEffectPreset.swift audio/EffectTransitionPolicy.swift audio/effects/*.swift)
if [[ "${1:-}" == --desktop ]]; then
 desktop_root="${ONGAKU_DESKTOP_ROOT:-../Ongaku-desktop}/Sources/OngakuDesktop"
 effect_sources=("$desktop_root/AudioEffectPreset.swift" "$desktop_root/EffectTransitionPolicy.swift"
  "$desktop_root/AudioEffectNode.swift" "$desktop_root/AudioEffectModuleRegistry.swift" "$desktop_root/"*AudioEffect.swift)
 shift
fi
source tests/spectral_transient_audit_support.sh
prepare_spectral_transient_audit "$audit_dir"
swiftc "${spectral_native_flags[@]}" -parse-as-library -O -suppress-warnings -module-cache-path "$audit_dir/cache" \
 "${effect_sources[@]}" tests/EffectAuditSupport.swift tests/GraphInitializationAudit.swift -o "$audit_dir/probe"
"$audit_dir/probe" "$@"
