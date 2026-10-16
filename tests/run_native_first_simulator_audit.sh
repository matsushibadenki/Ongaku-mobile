#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
: "${1:?Pass an installed iOS simulator device UUID}"
audit_device="$1"
audit_dir=$(mktemp -d /private/tmp/OngakuNativeFirst.XXXXXX)
trap 'rm -rf "$audit_dir"' EXIT
python3 - "$audit_dir" <<'PY'
from pathlib import Path
import shutil,sys
root=Path(sys.argv[1])
for name in ('audio','Ongaku.xcodeproj'):
    shutil.copytree(name, root/name)
shutil.copy2('AppInfo.plist',root/'AppInfo.plist')
shutil.copy2('tests/NativeFirstPlaybackAuditApp.swift',root/'audio/audioApp.swift')
p=root/'Ongaku.xcodeproj/project.pbxproj'
p.write_text(p.read_text().replace('PRODUCT_BUNDLE_IDENTIFIER = littlebuddha.audio;', 'PRODUCT_BUNDLE_IDENTIFIER = local.ongaku.native-first-audit;'))
PY
xcodebuild -project "$audit_dir/Ongaku.xcodeproj" -scheme audio -configuration Debug \
 -destination 'generic/platform=iOS Simulator' -derivedDataPath "$audit_dir/build" \
 ARCHS=arm64 CODE_SIGNING_ALLOWED=NO build > "$audit_dir/build.log" 2>&1 || { tail -n 60 "$audit_dir/build.log"; exit 1; }
xcrun simctl boot "$audit_device" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$audit_device" -b
xcrun simctl install "$audit_device" "$audit_dir/build/Build/Products/Debug-iphonesimulator/audio.app"
audit_container=$(xcrun simctl get_app_container "$audit_device" local.ongaku.native-first-audit data)
rm -f "$audit_container/Documents/native-first-result.txt"
xcrun simctl launch --terminate-running-process "$audit_device" local.ongaku.native-first-audit
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
