#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
: "${1:?Simulator UUID}" "${2:?Output directory}" "${3:?eager or deferred}"
mount_device="$1"; mount_out="$2"; mount_variant="$3"
mkdir -p "$mount_out"
mount_dir="${MOUNT_BUILD_ROOT:-$(mktemp -d /private/tmp/OngakuEffectsMount.XXXXXX)}"
# Keep the isolated build directory for reproducibility; never edit user settings/library.
if [[ "${MOUNT_SKIP_BUILD:-0}" != 1 ]]; then
python3 - "$mount_dir" "$mount_variant" <<'PY'
from pathlib import Path
import shutil,sys
root=Path(sys.argv[1]); variant=sys.argv[2]
for n in ['audio','Ongaku.xcodeproj']: shutil.copytree(n,root/n,dirs_exist_ok=True)
shutil.copy2('AppInfo.plist',root/'AppInfo.plist')
shutil.copy2('tests/EffectsMountAuditApp.swift',root/'audio/audioApp.swift')
p=root/'Ongaku.xcodeproj/project.pbxproj';p.write_text(p.read_text().replace('PRODUCT_BUNDLE_IDENTIFIER = littlebuddha.audio;', 'PRODUCT_BUNDLE_IDENTIFIER = local.ongaku.effects-mount;'))
p=root/'audio/ContentView.swift';s=p.read_text().replace('private struct EffectsTabContent: View','struct EffectsTabContent: View')
# Compile both variants into one instrumented app so alternating launches
# compare the same executable, with no compiler work between measurements.
a=s.index('            LazyVStack(spacing: 20) { // Defer offscreen effect cards.')
b=s.index('{',a)+1;depth=1
while depth:
 depth+=(s[b]=='{')-(s[b]=='}');b+=1
lazy=s[a:b];eager=lazy.replace('LazyVStack(spacing: 20) { // Defer offscreen effect cards.','VStack(spacing: 20) {',1)
s=s[:a]+'            if ProcessInfo.processInfo.arguments.contains("--eager") {\n'+eager+'\n            } else {\n'+lazy+'\n            }'+s[b:]
p.write_text(s)
p=root/'audio/MusicComponents.swift';s=p.read_text();a=s.index('struct EffectCard: View');b=s.index('    var body: some View {',a)+len('    var body: some View {');s=s[:b]+'\n        let _ = { EffectsMountCounter.cards += 1 }()'+s[b:];p.write_text(s)
p=root/'audio/AppearanceControls.swift';s=p.read_text()
s=s.replace('if let cached = Self.thumbImages.object(forKey: key)', 'if !ProcessInfo.processInfo.arguments.contains("--uncached"), let cached = Self.thumbImages.object(forKey: key)')
s=s.replace('        let format = UIGraphicsImageRendererFormat()', '        EffectsMountCounter.thumbs += 1\n        let format = UIGraphicsImageRendererFormat()')
s+='''
extension HardwareSlider {
 static func auditImage(_ appearance: AppAppearance, _ scale: CGFloat) -> UIImage {
  Self(value: .constant(0.5), range: 0...1, accent: .orange, appearance: appearance).thumbImage(displayScale: scale)
 }
}
@MainActor func auditThumbImage(_ appearance: AppAppearance, _ scale: CGFloat) -> UIImage {
 HardwareSlider.auditImage(appearance, scale)
}
'''
p.write_text(s)
shutil.copy2('tests/FullPreparationProbe.swift',root/'audio/FullPreparationProbe.swift')
import subprocess
subprocess.run(['python3','tests/instrument_full_preparation.py',str(root/'audio/HiResPlaybackEngine.swift')],check=True)

PY
xcodebuild -project "$mount_dir/Ongaku.xcodeproj" -scheme audio -configuration Debug \
 -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath "$mount_dir/build" \
 ARCHS=arm64 CODE_SIGNING_ALLOWED=NO INFOPLIST_KEY_UIApplicationSceneManifest_Generation=YES build > "$mount_out/build-$mount_variant.log" 2>&1
fi
xcrun simctl boot "$mount_device" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$mount_device" -b
xcrun simctl install "$mount_device" "$mount_dir/build/Build/Products/Debug-iphonesimulator/audio.app"
xcrun simctl privacy "$mount_device" revoke media-library local.ongaku.effects-mount
mount_data=$(xcrun simctl get_app_container "$mount_device" local.ongaku.effects-mount data)
rm -f "$mount_data/Documents/effects-mount.json" "$mount_data/Documents/pipeline-error.txt"
xcrun simctl launch --terminate-running-process "$mount_device" local.ongaku.effects-mount "--$mount_variant"
for ((i=0;i<180;i++)); do
 if [[ -f "$mount_data/Documents/pipeline-error.txt" ]]; then cat "$mount_data/Documents/pipeline-error.txt"; exit 1; fi
 if [[ -f "$mount_data/Documents/effects-mount.json" ]]; then
  cp "$mount_data/Documents/effects-mount.json" "$mount_out/$mount_variant.json"
  if [[ "$mount_variant" != pipeline ]]; then cp "$mount_data/Documents/effects-first.png" "$mount_out/$mount_variant.png"; fi
  cat "$mount_out/$mount_variant.json"
  exit 0
 fi
 sleep 1
done
echo 'FAIL: mount audit timed out' >&2; exit 1
