#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
: "${1:?Pass an installed iOS simulator device UUID}"
audit_device="$1"
audit_source=tests/NativeFirstPlaybackAuditApp.swift
if [[ "${2:-}" == "--destructive-stop" ]]; then
 audit_source=tests/DestructiveStopAuditApp.swift
elif [[ "${2:-}" == "--foreground-recovery" ]]; then
 audit_source=tests/ForegroundRecoveryAuditApp.swift
elif [[ "${2:-}" == "--track-progress" ]]; then
 audit_source=tests/TrackProgressAuditApp.swift
elif [[ "${2:-}" == "--gain-integration" ]]; then
 audit_source=tests/GainIntegrationAuditApp.swift
elif [[ "${2:-}" == --startup-cost ]]; then
 audit_source=tests/StartupCostAuditApp.swift
elif [[ -n "${2:-}" ]]; then
 echo 'Unknown audit mode'; exit 2
fi
audit_dir=$(mktemp -d /private/tmp/OngakuNativeFirst.XXXXXX)
trap 'rm -rf "$audit_dir"' EXIT
python3 - "$audit_dir" "$audit_source" <<'PY'
from pathlib import Path
import shutil,sys
root=Path(sys.argv[1])
for name in ('audio','Ongaku.xcodeproj'):
    shutil.copytree(name, root/name)
shutil.copy2('AppInfo.plist',root/'AppInfo.plist')
shutil.copy2(sys.argv[2],root/'audio/audioApp.swift')
if Path(sys.argv[2]).name == 'GainIntegrationAuditApp.swift':
    for name in ['NativeFirstPlaybackAuditApp.swift', 'DestructiveStopAuditApp.swift',
                 'ForegroundRecoveryAuditApp.swift', 'TrackProgressAuditApp.swift']:
        source=Path('tests',name).read_text().replace('@main ', '').replace('@main\n', '').replace('@MainActor private func run()', '@MainActor func run()')
        (root/'audio'/name).write_text(source)
p=root/'Ongaku.xcodeproj/project.pbxproj'
bundle={'StartupCostAuditApp.swift': 'local.ongaku.startup-audit',
        'GainIntegrationAuditApp.swift': 'local.ongaku.gain-integration-audit',
        'DestructiveStopAuditApp.swift': 'local.ongaku.stop-audit',
        'TrackProgressAuditApp.swift': 'local.ongaku.track-progress-audit',
        'ForegroundRecoveryAuditApp.swift': 'local.ongaku.foreground-audit'}.get(Path(sys.argv[2]).name, 'local.ongaku.native-first-audit')
p.write_text(p.read_text().replace('PRODUCT_BUNDLE_IDENTIFIER = littlebuddha.audio;', 'PRODUCT_BUNDLE_IDENTIFIER = '+bundle+';'))
PY
gain_flags=()
audit_defines=''
if [[ "${GAIN_AUDIO_THREAD:-0}" == 1 || "${2:-}" == --gain-integration ]]; then audit_defines+=' -DONGAKU_ENABLE_AUDIO_THREAD_GAIN'; fi
if [[ "${TRUE_PEAK:-0}" == 1 ]]; then audit_defines+=' -DONGAKU_ENABLE_TRUE_PEAK'; fi
if [[ "${2:-}" == --startup-cost ]]; then audit_defines+=' -DONGAKU_STARTUP_AUDIT'; fi
if [[ -n "$audit_defines" ]]; then gain_flags=("OTHER_SWIFT_FLAGS=\$(inherited)$audit_defines"); fi
optimization_flags=()
if [[ "${2:-}" == --gain-integration || "${2:-}" == --startup-cost ]]; then optimization_flags=(SWIFT_OPTIMIZATION_LEVEL=-O); fi
xcodebuild -project "$audit_dir/Ongaku.xcodeproj" -scheme audio -configuration Debug \
 -destination 'generic/platform=iOS Simulator' -derivedDataPath "$audit_dir/build" \
 ARCHS=arm64 CODE_SIGNING_ALLOWED=NO ${gain_flags[@]+"${gain_flags[@]}"} ${optimization_flags[@]+"${optimization_flags[@]}"} build > "$audit_dir/build.log" 2>&1 || { cp "$audit_dir/build.log" /private/tmp/ongaku-last-simulator-build.log; rg -n "error:" "$audit_dir/build.log" | head -n 20; tail -n 12 "$audit_dir/build.log"; exit 1; }
cp "$audit_dir/build.log" /private/tmp/ongaku-last-simulator-build.log
if [[ "${2:-}" == --startup-cost && -n "${STARTUP_BUILD_ONLY:-}" ]]; then
 mkdir -p "$STARTUP_BUILD_ONLY"
 cp -R "$audit_dir/build/Build/Products/Debug-iphonesimulator/audio.app" "$STARTUP_BUILD_ONLY/"
 exit 0
fi
xcrun simctl boot "$audit_device" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$audit_device" -b
audit_bundle=local.ongaku.native-first-audit
if [[ "${2:-}" == "--destructive-stop" ]]; then audit_bundle=local.ongaku.stop-audit; fi
if [[ "${2:-}" == "--foreground-recovery" ]]; then audit_bundle=local.ongaku.foreground-audit; fi
xcrun simctl install "$audit_device" "$audit_dir/build/Build/Products/Debug-iphonesimulator/audio.app"
if [[ "${2:-}" == "--track-progress" ]]; then audit_bundle=local.ongaku.track-progress-audit; fi
if [[ "${2:-}" == --gain-integration ]]; then audit_bundle=local.ongaku.gain-integration-audit; fi
if [[ "${2:-}" == --startup-cost ]]; then audit_bundle=local.ongaku.startup-audit; fi
audit_result=native-first-result.txt
if [[ "${2:-}" == --startup-cost ]]; then audit_result=startup-status.txt; fi
if [[ "${2:-}" == --gain-integration ]]; then audit_result=gain-integration-result.txt; fi
audit_container=$(xcrun simctl get_app_container "$audit_device" "$audit_bundle" data)
rm -f "$audit_container/Documents/$audit_result"
xcrun simctl launch --terminate-running-process "$audit_device" "$audit_bundle"
audit_iterations=180
if [[ "${2:-}" == --gain-integration ]]; then audit_iterations=900; fi
for ((i=0; i<audit_iterations; i++)); do
 if [[ -f "$audit_container/Documents/$audit_result" ]] && rg -q 'COMPLETE|FAIL:' "$audit_container/Documents/$audit_result"; then
   cat "$audit_container/Documents/$audit_result"
   rg -q '^COMPLETE$' "$audit_container/Documents/$audit_result"
   exit $?
 fi
 sleep 1
done
cat "$audit_container/Documents/$audit_result" 2>/dev/null || true
if [[ "${2:-}" == --gain-integration ]]; then
 cat "$audit_container/Documents/native-first-result.txt" 2>/dev/null || true
fi
echo 'FAIL: simulator audit timed out'
exit 1
