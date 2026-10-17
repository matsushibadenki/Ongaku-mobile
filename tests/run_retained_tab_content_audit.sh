#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
: "${SIMULATOR_UDID:?Set SIMULATOR_UDID to a booted iOS simulator}"
audit_dir=$(mktemp -d /private/tmp/OngakuRetainedTabs.XXXXXX)
audit_app="$audit_dir/TabAudit.app"
mkdir -p "$audit_app"
cat > "$audit_app/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.ongaku.retained-tab-audit</string>
<key>CFBundleExecutable</key><string>TabAudit</string>
<key>CFBundleName</key><string>Tab Audit</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>1</string>
<key>UILaunchScreen</key><dict/>
<key>UIDeviceFamily</key><array><integer>1</integer><integer>2</integer></array>
</dict></plist>
PLIST
xcrun --sdk iphonesimulator swiftc -target "$(uname -m)-apple-ios18.0-simulator" \
    -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
    audio/RetainedTabContent.swift tests/RetainedTabContentAuditApp.swift -o "$audit_app/TabAudit"
xcrun simctl terminate "$SIMULATOR_UDID" local.ongaku.retained-tab-audit 2>/dev/null || true
xcrun simctl install "$SIMULATOR_UDID" "$audit_app"
audit_data=$(xcrun simctl get_app_container "$SIMULATOR_UDID" local.ongaku.retained-tab-audit data)
audit_report="$audit_data/Documents/retained-tab-audit.txt"
rm -f "$audit_report"
xcrun simctl launch "$SIMULATOR_UDID" local.ongaku.retained-tab-audit
for ((attempt=0; attempt<30; attempt++)); do
    if [[ -f "$audit_report" ]]; then
        cat "$audit_report"
        printf '\n'
        exit 0
    fi
    sleep 1
done
printf 'FAIL: audit did not finish; inspect simulator crash logs. Build: %s\n' "$audit_dir" >&2
exit 1
