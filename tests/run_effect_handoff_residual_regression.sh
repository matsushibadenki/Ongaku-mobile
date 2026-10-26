#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
audit_dir=$(mktemp -d /private/tmp/OngakuEffectHandoff.XXXXXX)
trap 'rm -rf "$audit_dir"' EXIT
python3 tests/extract_sinc_measurement_fixture.py "$audit_dir/Sinc.swift"
effect_sources=(audio/AudioEffectPreset.swift audio/effects/*.swift)
gain_root="$PWD/audio"
gain_header="$gain_root"
if [[ "${1:-}" == --desktop ]]; then
 desktop_root="${ONGAKU_DESKTOP_ROOT:-../Ongaku-desktop}/Sources/OngakuDesktop"
 effect_sources=("$desktop_root/AudioEffectPreset.swift" "$desktop_root/AudioEffectNode.swift" "$desktop_root/AudioEffectModuleRegistry.swift" "$desktop_root/"*AudioEffect.swift)
 gain_root="${ONGAKU_DESKTOP_ROOT:-../Ongaku-desktop}/Sources/OngakuAudioDSP"
 gain_header="$gain_root/include"
fi
gain_flags=()
if [[ "${GAIN_GRAPH:-0}" == 1 ]]; then
 xcrun clang++ -std=c++20 -O2 -fobjc-arc -fblocks -I "$gain_header" -c "$gain_root/GainEnvelopeAudioUnit.mm" -o "$audit_dir/gain.o"
 gain_flags=(-D AUDIO_GAIN_TAIL_AUDIT  audio/AudioThreadGainStage.swift "$audit_dir/gain.o" -Xlinker -lc++)
fi
source tests/spectral_transient_audit_support.sh
prepare_spectral_transient_audit "$audit_dir"
swiftc "${spectral_native_flags[@]}" -parse-as-library -O -suppress-warnings -D EXTENDED_HANDOFF_MEASUREMENT \
 -module-cache-path "$audit_dir/cache" ${gain_flags[@]+"${gain_flags[@]}"} "${effect_sources[@]}" \
 tests/EffectAuditSupport.swift audio/PlaybackHandoffClock.swift "$audit_dir/Sinc.swift" \
 tests/PlaybackHandoffWaveformRegression.swift tests/EffectHandoffResidualRegression.swift -o "$audit_dir/handoff"
"$audit_dir/handoff"
if "$audit_dir/handoff" --reset-rack > "$audit_dir/negative.log" 2>&1; then
 echo 'FAIL: shared rack reset escaped residual checks' >&2; exit 1
fi
rg -q 'Shared rack residual failed|Handoff changed effect level' "$audit_dir/negative.log" || { cat "$audit_dir/negative.log"; exit 1; }
echo 'PASS: rejected shared-rack reset negative control'
