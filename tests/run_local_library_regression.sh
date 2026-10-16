#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
local_test_dir=$(mktemp -d /private/tmp/OngakuLocalLibrary.XXXXXX)
trap 'rm -rf "$local_test_dir"' EXIT
python3 tests/make_local_library_fixtures.py "$local_test_dir"
swiftc -parse-as-library -g -module-cache-path "$local_test_dir/module-cache" \
    audio/LocalMediaMetadataReader.swift audio/LocalAlbumFiles.swift \
    audio/SystemLibraryIndex.swift audio/AppLibraryModels.swift \
    tests/LocalLibraryRegression.swift -o "$local_test_dir/regression"
"$local_test_dir/regression" "$local_test_dir"
