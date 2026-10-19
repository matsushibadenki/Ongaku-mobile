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
p=root/'Ongaku.xcodeproj/project.pbxproj'
bundle={'DestructiveStopAuditApp.swift': 'local.ongaku.stop-audit',
        'ForegroundRecoveryAuditApp.swift': 'local.ongaku.foreground-audit'}.get(Path(sys.argv[2]).name, 'local.ongaku.native-first-audit')
p.write_text(p.read_text().replace('PRODUCT_BUNDLE_IDENTIFIER = littlebuddha.audio;', 'PRODUCT_BUNDLE_IDENTIFIER = '+bundle+';'))
PY
xcodebuild -project "$audit_dir/Ongaku.xcodeproj" -scheme audio -configuration Debug \
 -destination 'generic/platform=iOS Simulator' -derivedDataPath "$audit_dir/build" \
 ARCHS=arm64 CODE_SIGNING_ALLOWED=NO build > "$audit_dir/build.log" 2>&1 || { tail -n 60 "$audit_dir/build.log"; exit 1; }
xcrun simctl boot "$audit_device" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$audit_device" -b
audit_bundle=local.ongaku.native-first-audit
if [[ "${2:-}" == "--destructive-stop" ]]; then audit_bundle=local.ongaku.stop-audit; fi
if [[ "${2:-}" == "--foreground-recovery" ]]; then audit_bundle=local.ongaku.foreground-audit; fi
xcrun simctl install "$audit_device" "$audit_dir/build/Build/Products/Debug-iphonesimulator/audio.app"
audit_container=$(xcrun simctl get_app_container "$audit_device" "$audit_bundle" data)
rm -f "$audit_container/Documents/native-first-result.txt"
xcrun simctl launch --terminate-running-process "$audit_device" "$audit_bundle"
for ((i=0; i<180; i++)); do
 if [[ -f "$audit_container/Documents/native-first-result.txt" ]] && rg -q 'COMPLETE|FAIL:' "$audit_container/Documents/native-first-result.txt"; then
   cat "$audit_container/Documents/native-first-result.txt"
   rg -q '^COMPLETE$' "$audit_container/Documents/native-first-result.txt"
   exit $?
 fi
 sleep 1
done
cat "$audit_container/Documents/native-first-result.txt" 2>/dev/null || true
exit 1
