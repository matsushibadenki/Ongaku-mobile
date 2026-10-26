#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
conversion_test_dir=$(mktemp -d /private/tmp/OngakuSourceConversion.XXXXXX)
trap 'rm -rf "$conversion_test_dir"' EXIT
source tests/spectral_transient_audit_support.sh
prepare_spectral_transient_audit "$conversion_test_dir"
swiftc "${spectral_native_flags[@]}" -parse-as-library -O -suppress-warnings -module-cache-path "$conversion_test_dir/module-cache" \
    audio/AudioEffectPreset.swift audio/effects/*.swift tests/EffectAuditSupport.swift \
    tests/SourcePathConversionRegression.swift -o "$conversion_test_dir/source-conversion-tests"
"$conversion_test_dir/source-conversion-tests"
