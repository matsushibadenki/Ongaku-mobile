#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
m4a_test_dir=$(mktemp -d /private/tmp/OngakuM4ALyrics.XXXXXX)
trap 'rm -rf "$m4a_test_dir"' EXIT
swiftc -parse-as-library -O -module-cache-path "$m4a_test_dir/module-cache" \
    audio/Lyrics.swift audio/LyricsTagEditor.swift audio/M4ALyricsTagEditor.swift \
    audio/JapaneseLyricsSite.swift audio/Localization.swift audio/AppLibraryModels.swift \
    tests/M4ALyricsRegression.swift -o "$m4a_test_dir/m4a-lyrics"
python3 tests/verify_m4a_lyrics.py "$m4a_test_dir/m4a-lyrics" "$m4a_test_dir"
