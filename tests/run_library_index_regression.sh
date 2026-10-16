#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
library_test_dir=$(mktemp -d /private/tmp/OngakuLibraryIndex.XXXXXX)
swiftc -O -module-cache-path "$library_test_dir/module-cache" \
    audio/AppLibraryModels.swift audio/AppLibraryStore.swift audio/SystemLibraryIndex.swift audio/LocalAlbumFiles.swift \
    tests/LibraryIndexRegression.swift -o "$library_test_dir/library-index-regression"
"$library_test_dir/library-index-regression"
