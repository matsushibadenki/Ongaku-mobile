#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
spectral_dir=$(mktemp -d /private/tmp/OngakuSpectral.XXXXXX)
trap 'rm -rf "$spectral_dir"' EXIT
source tests/spectral_transient_audit_support.sh
prepare_spectral_transient_audit "$spectral_dir"
xcrun clang++ -std=c++20 -O2 tests/SpectralTransientDSPTests.cpp -o "$spectral_dir/dsp"
"$spectral_dir/dsp"
xcrun clang++ -std=c++20 -O1 -g -fsanitize=address,undefined tests/SpectralTransientDSPTests.cpp -o "$spectral_dir/sanitized"
"$spectral_dir/sanitized"
xcrun clang++ -std=c++20 -O2 -fobjc-arc tests/SpectralTransientAudioUnitTests.mm "$spectral_dir/SpectralTransient.o" -framework AVFoundation -framework AudioToolbox -framework Foundation -o "$spectral_dir/au"
"$spectral_dir/au"
mkdir -p "$spectral_dir/negative/audio" "$spectral_dir/negative/tests"
cp audio/SpectralTransientDSP.hpp audio/TruePeakDSP.hpp "$spectral_dir/negative/audio/"
cp tests/SpectralTransientDSPTests.cpp "$spectral_dir/negative/tests/"
python3 - "$spectral_dir/negative/audio/SpectralTransientDSP.hpp" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]);s=p.read_text();old='rampLength=std::max(1u,unsigned(rate*.020));'
assert old in s
p.write_text(s.replace(old,'rampLength=1;'))
PY
xcrun clang++ -std=c++20 -O2 "$spectral_dir/negative/tests/SpectralTransientDSPTests.cpp" -o "$spectral_dir/negative/dsp"
if "$spectral_dir/negative/dsp" > "$spectral_dir/negative.log" 2>&1; then
 echo 'FAIL: abrupt bypass escaped ramp test' >&2;exit 1
fi
rg -q 'OFF first sample does not jump|ON first sample does not jump' "$spectral_dir/negative.log"
echo 'PASS: rejected abrupt-ramp negative control'
