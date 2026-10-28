#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $# != 1 ]]; then echo "usage: $0 OUTPUT_DIR" >&2; exit 2; fi
out="$1"
mkdir -p "$out/fixtures" "$out/mobile" "$out/desktop" "$out/cache"
python3 tests/generate_vocal_mix_fixtures.py "$out/fixtures"
tests/run_vocal_presence_mix_render.sh "$out/fixtures" "$out/mobile"
tests/run_vocal_presence_mix_render.sh "$out/fixtures" "$out/desktop" desktop
swiftc -module-cache-path "$out/cache" -parse-as-library -O audio/IntegratedLoudnessMeter.swift tests/VocalPresenceMixLoudness.swift -o "$out/loudness"
swiftc -module-cache-path "$out/cache" -parse-as-library -O audio/IntegratedLoudnessMeter.swift tests/VocalPresenceMixMatchCheck.swift -o "$out/check"
for platform in mobile desktop; do
 "$out/loudness" "$out/$platform" "$out/$platform-levels.json"
 OPENBLAS_NUM_THREADS=1 python3 tests/analyze_vocal_presence_mix.py "$out/$platform" "$out/$platform-levels.json" "$out/$platform-comparison.json"
 "$out/check" "$out/$platform" "$out/$platform-comparison.json"
done
python3 - "$out" <<'PY'
import json, pathlib, sys
root=pathlib.Path(sys.argv[1]); a=root/'mobile';b=root/'desktop'
files=sorted(a.glob('*.f32'))
assert files and len(files)==len(list(b.glob('*.f32')))
rows=[]
for file in files:
 left=file.read_bytes();right=(b/file.name).read_bytes()
 assert left==right, 'platform mismatch: '+file.name
 rows.append(file.name)
(root/'platform-exact.json').write_text(json.dumps(rows,indent=2)+'\n')
print('PASS',len(rows),'Mac-native platform outputs are byte-identical')
PY
