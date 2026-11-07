#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
timing_dir=$(mktemp -d /private/tmp/OngakuCancelTiming.XXXXXX)
trap 'rm -rf "$timing_dir"' EXIT
python3 - "$timing_dir/Timing.swift" <<'PY'
from pathlib import Path
import sys
s=Path('audio/HiResPlaybackEngine.swift').read_text()
a=s.index('nonisolated private final class PreparationCancellationTiming:');b=s.index('{',a)+1;depth=1
while depth:depth+=(s[b]=='{')-(s[b]=='}');b+=1
assert 'cancelLatencyMs=\\(cancelLatency)' in s
assert 'cancellationTiming.markRequested()\n                worker.cancel()' in s
Path(sys.argv[1]).write_text('import Foundation\n'+s[a:b].replace('private final class','final class',1))
PY
swiftc -parse-as-library -O -module-cache-path "$timing_dir/cache" "$timing_dir/Timing.swift" tests/PreparationCancelTimingRegression.swift -o "$timing_dir/check"
"$timing_dir/check"
