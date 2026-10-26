#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
audit_build_dir=$(mktemp -d /private/tmp/OngakuEffectAudit.XXXXXX)
trap 'rm -rf "$audit_build_dir"' EXIT
source tests/spectral_transient_audit_support.sh
prepare_spectral_transient_audit "$audit_build_dir"
swiftc "${spectral_native_flags[@]}" -O -module-cache-path "$audit_build_dir/module-cache" \
    audio/AudioEffectPreset.swift audio/effects/*.swift \
    tests/EffectAuditSupport.swift tests/EffectEQLifecycleAudit.swift tests/EffectMatrixAudit.swift -o "$audit_build_dir/effect-audit"
"$audit_build_dir/effect-audit" "$@"
