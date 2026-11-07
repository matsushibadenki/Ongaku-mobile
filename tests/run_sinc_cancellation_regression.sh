#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
cancel_root="${1:-$PWD}"
cancel_mode="${2:---enforce}"
cancel_dir=$(mktemp -d /private/tmp/OngakuSincCancel.XXXXXX)
trap 'rm -rf "$cancel_dir"' EXIT
python3 tests/sinc-benchmark/extract_fixture.py "$cancel_dir/Shipping.swift" "$cancel_root"
cat >> "$cancel_dir/Shipping.swift" <<'SWIFT'
extension ShippingSincMeasurement {
 static func auditClearCache() { sincKernelCacheLock.lock(); sincKernelCache.removeAll(); sincKernelCacheLock.unlock() }
 static func auditCacheCount() -> Int { sincKernelCacheLock.lock(); defer {sincKernelCacheLock.unlock()}; return sincKernelCache.count }
}
SWIFT
swiftc -parse-as-library -O -suppress-warnings -module-cache-path "$cancel_dir/cache" \
 "$cancel_dir/Shipping.swift" tests/SincCancellationRegression.swift -o "$cancel_dir/check"
"$cancel_dir/check" "$cancel_mode"
