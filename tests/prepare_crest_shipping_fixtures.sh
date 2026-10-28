#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $# != 1 ]]; then echo 'usage: prepare_crest_shipping_fixtures.sh OUTPUT_DIR' >&2; exit 2; fi
fixtures="$1";work=$(mktemp -d /private/tmp/OngakuCrestSinc.XXXXXX)
trap 'rm -rf "$work"' EXIT
python3 tests/generate_crest_peak_fixtures.py "$fixtures"
cp "$fixtures/crest-96000.f32" "$fixtures/crest-polyphase-96000.f32"
python3 tests/sinc-benchmark/extract_fixture.py "$work/ShippingSinc.swift"
swiftc -parse-as-library -O -suppress-warnings -module-cache-path "$work/cache" "$work/ShippingSinc.swift" tests/CrestShippingSincFixture.swift -o "$work/sinc-fixture"
"$work/sinc-fixture" "$fixtures"
python3 - "$fixtures" <<'PY'
import json,hashlib,sys
from pathlib import Path
import numpy as np
root=Path(sys.argv[1]);rows=[]
for name,method,rate in [('crest-44100.f32','source',44100),('crest-polyphase-96000.f32','scipy resample_poly',96000),('crest-96000.f32','shipping chunked Precision Sinc apodizing eco',96000)]:
 data=(root/name).read_bytes();x=np.frombuffer(data,dtype='<f4')
 rows.append({'name':name,'method':method,'sampleRate':rate,'frames':len(x)//2,'samplePeak':float(np.max(abs(x))),'rms':float(np.sqrt(np.mean(x.astype('float64')**2))),'sha256':hashlib.sha256(data).hexdigest()})
(root/'manifest.json').write_text(json.dumps(rows,indent=2)+'\n')
PY
