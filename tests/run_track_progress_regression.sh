#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
audit_dir=$(mktemp -d /private/tmp/OngakuTrackProgress.XXXXXX)
trap 'rm -rf "$audit_dir"' EXIT
for fault in normal no-source-watchdog default-mode-timer; do
 python3 tests/extract_track_progress_fixture.py "$audit_dir/fixture.swift" "--$fault"
 swiftc -parse-as-library -O -module-cache-path "$audit_dir/cache" \
  audio/PlaybackTransportPolicy.swift "$audit_dir/fixture.swift" tests/TrackProgressRegression.swift -o "$audit_dir/test"
 if [[ "$fault" == normal ]]; then
  "$audit_dir/test"
 elif "$audit_dir/test" > "$audit_dir/$fault.log" 2>&1; then
  echo "FAIL: $fault negative control accepted"; exit 1
 else
  if [[ "$fault" == no-source-watchdog ]]; then
   rg -q 'healthy output graph hid frozen source timeline' "$audit_dir/$fault.log"
  else
   rg -q 'track-end timer froze during UI tracking' "$audit_dir/$fault.log"
  fi
  echo "PASS: negative control rejects $fault"
 fi
done
