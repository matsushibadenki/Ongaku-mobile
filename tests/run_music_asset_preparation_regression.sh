#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
asset_test_dir=$(mktemp -d /private/tmp/OngakuMusicAsset.XXXXXX)
trap 'rm -rf "$asset_test_dir"' EXIT
swiftc -parse-as-library -O -module-cache-path "$asset_test_dir/module-cache" \
 audio/MusicAssetPreparation.swift tests/MusicAssetPreparationRegression.swift -o "$asset_test_dir/test"
"$asset_test_dir/test" "$@"
