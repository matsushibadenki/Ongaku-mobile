#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
effects_events_dir=$(mktemp -d /private/tmp/OngakuEffectEvents.XXXXXX)
trap 'rm -rf "$effects_events_dir"' EXIT
python3 tests/extract_effect_events_fixture.py "$effects_events_dir/Model.swift"
swiftc -O -module-cache-path "$effects_events_dir/cache" \
 "$effects_events_dir/Model.swift" audio/CoalescedViewUpdates.swift \
 tests/EffectEventsRegression.swift -o "$effects_events_dir/check"
"$effects_events_dir/check"
