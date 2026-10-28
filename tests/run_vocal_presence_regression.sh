#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
vocal_dir=$(mktemp -d /private/tmp/OngakuVocalPresence.XXXXXX)
trap 'rm -rf "$vocal_dir"' EXIT
source tests/spectral_transient_audit_support.sh
prepare_spectral_transient_audit "$vocal_dir"
cmp audio/effects/VocalPresenceAudioEffect.swift "${ONGAKU_DESKTOP_ROOT:-../Ongaku-desktop}/Sources/OngakuDesktop/VocalPresenceAudioEffect.swift"
swiftc "${spectral_native_flags[@]}" -parse-as-library -O -suppress-warnings -module-cache-path "$vocal_dir/cache" \
 audio/AudioEffectPreset.swift audio/effects/*.swift tests/EffectAuditSupport.swift tests/VocalPresenceRegression.swift -o "$vocal_dir/test"
"$vocal_dir/test"
