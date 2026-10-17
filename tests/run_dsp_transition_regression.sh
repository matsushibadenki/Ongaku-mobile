#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
dsp_transition_dir=$(mktemp -d /private/tmp/OngakuDSPTransition.XXXXXX)
trap 'rm -rf "$dsp_transition_dir"' EXIT
python3 tests/extract_dsp_transition_fixture.py "$dsp_transition_dir/ShippingDSPTransition.swift"
python3 tests/extract_effect_mode_fixture.py "$dsp_transition_dir/ShippingEffectSelection.swift"
swiftc -parse-as-library -O -suppress-warnings -module-cache-path "$dsp_transition_dir/module-cache" \
    audio/IntegratedLoudnessMeter.swift audio/EffectMeterObservation.swift audio/EffectTransitionPolicy.swift audio/AudioEffectPreset.swift audio/effects/*.swift tests/EffectAuditSupport.swift \
    "$dsp_transition_dir/ShippingDSPTransition.swift" tests/DSPTransitionRegression.swift tests/GainTransitionRegression.swift tests/EffectModeRegression.swift \
    "$dsp_transition_dir/ShippingEffectSelection.swift" \
    -o "$dsp_transition_dir/dsp-transition"
"$dsp_transition_dir/dsp-transition" "$@"
if "$dsp_transition_dir/dsp-transition" "$@" --unprotected-fixture > "$dsp_transition_dir/negative-control.log" 2>&1; then
    echo "FAIL: unprotected parameter update escaped mutation guards" >&2
    exit 1
fi
if ! rg -q 'Continuous update bypassed interpolation' "$dsp_transition_dir/negative-control.log"; then
    cat "$dsp_transition_dir/negative-control.log" >&2
    exit 1
fi
echo "PASS: transition guards reject parameter changes that bypass interpolation"
if [[ $# -gt 0 ]] && [[ " ${*} " == *" --gain-path "* ]]; then
    if "$dsp_transition_dir/dsp-transition" --gain-path --duplicate-gain-fixture > "$dsp_transition_dir/duplicate-gain.log" 2>&1; then
        echo "FAIL: duplicate gain planning escaped guards" >&2
        exit 1
    fi
    rg -q 'Gain planning repeated or missed during one commit' "$dsp_transition_dir/duplicate-gain.log"
    if "$dsp_transition_dir/dsp-transition" --gain-path --inactive-gain-fixture > "$dsp_transition_dir/inactive-gain.log" 2>&1; then
        echo "FAIL: inactive-only gain recalculation escaped guards" >&2
        exit 1
    fi
    rg -q 'Disabled-only changes triggered gain or mute' "$dsp_transition_dir/inactive-gain.log"
    echo "PASS: gain guards reject duplicate planning and gain writes from inactive-only edits"
fi

if "$dsp_transition_dir/dsp-transition" "$@" --mute-fixture > "$dsp_transition_dir/mute-control.log" 2>&1; then
    echo "FAIL: continuous-control mute regression was not detected" >&2
    exit 1
fi
rg -q 'Continuous controls changed output envelope' "$dsp_transition_dir/mute-control.log"
echo "PASS: continuity guards reject output muting during parameter gestures"
