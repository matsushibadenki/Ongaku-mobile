#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
audit_build_dir=$(mktemp -d /private/tmp/OngakuEffectAudit.XXXXXX)
swiftc -O -module-cache-path "$audit_build_dir/module-cache" \
    audio/AudioEffectPreset.swift audio/effects/*.swift \
    tests/EffectAuditSupport.swift tests/EffectMatrixAudit.swift -o "$audit_build_dir/effect-audit"
"$audit_build_dir/effect-audit"
