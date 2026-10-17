#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
audit_dir=$(mktemp -d /private/tmp/OngakuPreparationDiagnostics.XXXXXX)
trap 'rm -rf "$audit_dir"' EXIT
compile() {
 swiftc -parse-as-library -O -module-cache-path "$audit_dir/module-cache" \
  audio/AudioProcessingPolicy.swift audio/AudioPreparationFailure.swift audio/MusicAssetPreparation.swift \
  audio/RemoteAudioReadiness.swift audio/StreamingAudioFilePreparation.swift \
  "$audit_dir/ShippingPreparationPreflight.swift" tests/PreparationDiagnosticsRegression.swift -o "$audit_dir/test"
}
python3 tests/extract_preparation_diagnostics_fixture.py "$audit_dir/ShippingPreparationPreflight.swift"
compile
"$audit_dir/test"
python3 tests/extract_preparation_diagnostics_fixture.py "$audit_dir/ShippingPreparationPreflight.swift" --capacity-for-all-fixture
compile
if "$audit_dir/test" > "$audit_dir/negative.log" 2>&1; then
 echo 'FAIL: capacity-for-all mutation escaped diagnostics' >&2; exit 1
fi
rg -q 'Unreadable source was mislabeled as capacity exceeded' "$audit_dir/negative.log" || { cat "$audit_dir/negative.log"; exit 1; }
echo 'PASS: rejected the former capacity-for-all failure classification'
