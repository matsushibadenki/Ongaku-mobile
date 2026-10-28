#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $# != 4 ]]; then echo 'usage: run_real_music_simulator_audit.sh DEVICE INPUT_A_CAF INPUT_B_CAF OUTPUT_DIR' >&2; exit 2; fi
device="$1";file_a="$2";file_b="$3";output="$4";work=$(mktemp -d /private/tmp/OngakuMusicSimulator.XXXXXX)
trap 'rm -rf "$work"' EXIT
mkdir -p "$output"
python3 - "$work" <<'PY'
from pathlib import Path
import shutil,sys
root=Path(sys.argv[1])
for name in ['audio','Ongaku.xcodeproj']:shutil.copytree(name,root/name)
shutil.copy2('AppInfo.plist',root/'AppInfo.plist')
shutil.copy2('tests/RealMusicPlaybackAuditApp.swift',root/'audio/audioApp.swift')
p=root/'audio/HiResPlaybackEngine.swift';s=p.read_text();old='''                if isFinal {
                    self.renderHealthMonitor.recordTapDelivery(''';new='''                if isFinal {
                    MusicAuditCapture.shared.capture(buffer)
                    self.renderHealthMonitor.recordTapDelivery('''
assert s.count(old)==1;p.write_text(s.replace(old,new))
p=root/'Ongaku.xcodeproj/project.pbxproj';s=p.read_text();p.write_text(s.replace('PRODUCT_BUNDLE_IDENTIFIER = littlebuddha.audio;', 'PRODUCT_BUNDLE_IDENTIFIER = local.ongaku.music-output-audit;'))
PY
xcodebuild -project "$work/Ongaku.xcodeproj" -scheme audio -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath "$work/build" ARCHS=arm64 CODE_SIGNING_ALLOWED=NO build > "$work/build.log" 2>&1 || { cp "$work/build.log" "$output/build-failure.log"; rg -n 'error:' "$work/build.log" | head -20; exit 1; }
xcrun simctl boot "$device" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$device" -b
bundle=local.ongaku.music-output-audit
xcrun simctl install "$device" "$work/build/Build/Products/Debug-iphonesimulator/audio.app"
container=$(xcrun simctl get_app_container "$device" "$bundle" data)
mkdir -p "$container/Documents"
rm -f "$container/Documents/music-audit-result.txt" "$container/Documents/captured.f32"
cp "$file_a" "$container/Documents/input-0.caf"
cp "$file_b" "$container/Documents/input-1.caf"
xcrun simctl launch --terminate-running-process "$device" "$bundle"
for ((i=0;i<120;i++)); do
 if [[ -f "$container/Documents/music-audit-result.txt" ]] && rg -q 'COMPLETE|FAIL:' "$container/Documents/music-audit-result.txt"; then
  cp "$container/Documents/music-audit-result.txt" "$output/simulator-report.txt"
  cat "$output/simulator-report.txt"
  rg -q '^COMPLETE$' "$output/simulator-report.txt"
  cp "$container/Documents/captured.f32" "$output/simulator-captured.f32"
  exit 0
 fi
 sleep 1
done
cat "$container/Documents/music-audit-result.txt" 2>/dev/null || true
echo 'FAIL: simulator audio audit timed out' >&2
exit 1
