#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
transport_dir=$(mktemp -d /private/tmp/OngakuTransport.XXXXXX)
trap 'rm -rf "$transport_dir"' EXIT
python3 tests/extract_transport_continuity_fixture.py "$transport_dir/ShippingTransport.swift"
swiftc -parse-as-library -O -module-cache-path "$transport_dir/cache" \
 audio/EffectTransitionPolicy.swift "$transport_dir/ShippingTransport.swift" \
 tests/TransportContinuityRegression.swift -o "$transport_dir/transport"
"$transport_dir/transport"
if "$transport_dir/transport" --abrupt-fixture > "$transport_dir/negative.log" 2>&1; then
 echo 'FAIL: abrupt transport escaped PCM guard'; exit 1
fi
rg -q 'transport PCM contains abrupt boundary' "$transport_dir/negative.log"
echo 'PASS: PCM guard rejects abrupt source start/stop'
