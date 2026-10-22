#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
: "${1:?Pass a Simulator UUID}" "${2:?Pass a dedicated output directory}"
device="$1"
out="$2"
mkdir -p "$out"
configs=(ordinary gain gain-truepeak)
for config in "${configs[@]}"; do
 gain=0; peak=0
 if [[ "$config" != ordinary ]]; then gain=1; fi
 if [[ "$config" == gain-truepeak ]]; then peak=1; fi
 GAIN_AUDIO_THREAD="$gain" TRUE_PEAK="$peak" STARTUP_BUILD_ONLY="$out/$config" bash tests/run_native_first_simulator_audit.sh "$device" --startup-cost > "$out/build-$config.log" 2>&1
done
xcrun simctl boot "$device" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$device" -b
bundle=local.ongaku.startup-audit
for round in 0 1 2; do
 for offset in 0 1 2; do
  config="${configs[$(((round+offset)%3))]}"
  xcrun simctl terminate "$device" "$bundle" >/dev/null 2>&1 || true
  xcrun simctl install "$device" "$out/$config/audio.app"
  container=$(xcrun simctl get_app_container "$device" "$bundle" data)
  rm -f "$container/Documents/startup-status.txt" "$container/Documents/startup-result.json"
  xcrun simctl launch --terminate-running-process "$device" "$bundle"
  complete=0
  for ((i=0;i<180;i++)); do
   if [[ -f "$container/Documents/startup-status.txt" ]]; then
    cat "$container/Documents/startup-status.txt"
    if ! rg -q '^COMPLETE$' "$container/Documents/startup-status.txt"; then exit 1; fi
    cp "$container/Documents/startup-result.json" "$out/ios-$config-$round.json"
    complete=1; break
   fi
   sleep 1
  done
  if [[ "$complete" != 1 ]]; then echo 'FAIL: startup audit timeout'; exit 1; fi
  xcrun simctl terminate "$device" "$bundle" >/dev/null 2>&1 || true
 done
done
