#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
fallback_dir=$(mktemp -d /private/tmp/OngakuTransientFallback.XXXXXX)
trap 'rm -rf "$fallback_dir"' EXIT
source tests/spectral_transient_audit_support.sh
prepare_spectral_transient_audit "$fallback_dir"
swiftc "${spectral_native_flags[@]}" -parse-as-library -O -suppress-warnings -module-cache-path "$fallback_dir/cache" \
 audio/AudioEffectPreset.swift audio/effects/*.swift tests/EffectAuditSupport.swift \
 tests/SpectralTransientFallbackRegression.swift -o "$fallback_dir/check"
"$fallback_dir/check"
