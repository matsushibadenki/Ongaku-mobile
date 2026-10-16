#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
peak_dir=$(mktemp -d /private/tmp/OngakuFinalPeak.XXXXXX)
trap 'rm -rf "$peak_dir"' EXIT
peak_flags=(-D ONGAKU_PEAK_AUDIT)
peak_sources=(audio/effects/EffectOutputSafety.swift)
if [[ "${1:-}" == "--desktop" ]]; then
 shift
 python3 - "$peak_dir/DesktopProtection.swift" "${ONGAKU_DESKTOP_SOURCE:-/Users/Shared/Program/Xcode/Ongaku-desktop/Sources/OngakuDesktop/AudioEffectNode.swift}" <<'PY'
import sys
from pathlib import Path
s=Path(sys.argv[2]).read_text()
start=s.index('final class EffectOutputProtection {')
level=0
for i in range(s.index('{',start),len(s)):
    level += (s[i]=='{')-(s[i]=='}')
    if level==0:
        Path(sys.argv[1]).write_text('import AVFoundation\n'+s[start:i+1]+'\n')
        break
else: raise RuntimeError('Unbalanced desktop protection class')
PY
 peak_flags=(-D DESKTOP_PEAK_AUDIT)
 peak_sources=("$peak_dir/DesktopProtection.swift")
fi
xcrun clang++ -std=c++20 -O2 -fobjc-arc -fblocks -c audio/TruePeakAudioUnit.mm -o "$peak_dir/TruePeak.o"
swiftc -import-objc-header audio/TruePeakAudioUnit.h "$peak_dir/TruePeak.o" -lc++ -parse-as-library -O -module-cache-path "$peak_dir/module-cache" "${peak_flags[@]}" \
 "${peak_sources[@]}" tests/ReconstructedPeak.swift tests/FinalOutputPeakRegression.swift -o "$peak_dir/test"
"$peak_dir/test" "$@"
