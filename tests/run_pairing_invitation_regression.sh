#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
pairing_test_dir=$(mktemp -d /private/tmp/OngakuPairing.XXXXXX)
trap 'rm -rf "$pairing_test_dir"' EXIT
python3 tests/extract_pairing_fixture.py "$pairing_test_dir/ShippingPairing.swift"
swiftc -parse-as-library -O -module-cache-path "$pairing_test_dir/cache" \
 "$pairing_test_dir/ShippingPairing.swift" tests/PairingInvitationRegression.swift -o "$pairing_test_dir/check"
"$pairing_test_dir/check"
