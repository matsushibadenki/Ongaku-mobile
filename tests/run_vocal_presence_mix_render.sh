#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d /private/tmp/OngakuVocalMixCompile.XXXXXX)
trap 'rm -rf "$work"' EXIT
source tests/spectral_transient_audit_support.sh
prepare_spectral_transient_audit "$work"
if [[ "${3:-mobile}" == desktop ]]; then
 desktop_root="${ONGAKU_DESKTOP_ROOT:-../Ongaku-desktop}/Sources/OngakuDesktop"
 sources=("$desktop_root/AudioEffectPreset.swift" "$desktop_root/AudioEffectNode.swift" "$desktop_root/AudioEffectModuleRegistry.swift" "$desktop_root/"*AudioEffect.swift)
else
 sources=(audio/AudioEffectPreset.swift audio/effects/*.swift)
fi
swiftc "${spectral_native_flags[@]}" -parse-as-library -O -suppress-warnings -module-cache-path "$work/cache" "${sources[@]}" tests/EffectAuditSupport.swift tests/VocalPresenceMixRender.swift -o "$work/render"
"$work/render" "$1" "$2"
