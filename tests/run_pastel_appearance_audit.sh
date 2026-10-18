#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
: "${1:?Pass simulator UUID}"
: "${2:?Pass screenshot output directory}"
pastel_device="$1"
pastel_output="$2"
pastel_dir=$(mktemp -d /private/tmp/OngakuPastelAudit.XXXXXX)
trap 'rm -rf "$pastel_dir"' EXIT
python3 - "$pastel_dir" <<'PY'
from pathlib import Path
import shutil,sys
root=Path(sys.argv[1])
for name in ('audio','Ongaku.xcodeproj'):
 shutil.copytree(name,root/name)
shutil.copy2('AppInfo.plist',root/'AppInfo.plist')
shutil.copy2('tests/PastelAppearanceAuditApp.swift',root/'audio/audioApp.swift')
p=root/'Ongaku.xcodeproj/project.pbxproj'
p.write_text(p.read_text().replace('PRODUCT_BUNDLE_IDENTIFIER = littlebuddha.audio;', 'PRODUCT_BUNDLE_IDENTIFIER = local.ongaku.pastel-audit;'))
# Set only the initial visualization in the isolated audit copy; retain all production layout code.
p=root/'audio/ContentView.swift'
p.write_text(p.read_text().replace('private var artworkMode: ArtworkMode = .thumbnail', 'private var artworkMode: ArtworkMode = .vuMeter'))
PY
xcodebuild -project "$pastel_dir/Ongaku.xcodeproj" -scheme audio -configuration Debug \
 -destination 'generic/platform=iOS Simulator' -derivedDataPath "$pastel_dir/build" \
 ARCHS=arm64 CODE_SIGNING_ALLOWED=NO INFOPLIST_KEY_UIApplicationSceneManifest_Generation=NO build > "$pastel_dir/build.log" 2>&1 || { rg -n -C 4 "error:" "$pastel_dir/build.log"; tail -n 12 "$pastel_dir/build.log"; exit 1; }
xcrun simctl boot "$pastel_device" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$pastel_device" -b
xcrun simctl install "$pastel_device" "$pastel_dir/build/Build/Products/Debug-iphonesimulator/audio.app"
pastel_data=$(xcrun simctl get_app_container "$pastel_device" local.ongaku.pastel-audit data)
rm -f "$pastel_data/Documents/pastel-result.txt"
xcrun simctl launch --terminate-running-process "$pastel_device" local.ongaku.pastel-audit -AppleLanguages '(ja)'
for ((i=0; i<90; i++)); do
 if [[ -f "$pastel_data/Documents/pastel-result.txt" ]] && rg -q 'COMPLETE|FAIL:' "$pastel_data/Documents/pastel-result.txt"; then
  mkdir -p "$pastel_output"
  cp "$pastel_data/Documents/"*.png "$pastel_output/"
  cp "$pastel_data/Documents/pastel-result.txt" "$pastel_output/"
  cat "$pastel_output/pastel-result.txt"
  rg -q '^COMPLETE$' "$pastel_output/pastel-result.txt"
  exit $?
 fi
 sleep 1
done
cat "$pastel_data/Documents/pastel-result.txt" 2>/dev/null || true
exit 1
