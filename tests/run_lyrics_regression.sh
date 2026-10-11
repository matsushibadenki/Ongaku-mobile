#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
lyrics_test_dir=$(mktemp -d /private/tmp/OngakuLyrics.XXXXXX)
trap 'rm -rf "$lyrics_test_dir"' EXIT
swiftc -parse-as-library -O -module-cache-path "$lyrics_test_dir/module-cache" \
    audio/Lyrics.swift audio/LyricsTagEditor.swift audio/M4ALyricsTagEditor.swift audio/LyricsViewModel.swift audio/Localization.swift audio/AppLibraryModels.swift tests/LyricsRegression.swift \
    -o "$lyrics_test_dir/lyrics-regression"
"$lyrics_test_dir/lyrics-regression"
# Optional independent codec verification: compressed packets and decoded PCM
# must stay identical after embedding, with unrelated metadata still readable.
if command -v ffmpeg >/dev/null && command -v ffprobe >/dev/null; then
    for ext in mp3 flac; do
        ffmpeg -v error -f lavfi -i 'sine=frequency=997:duration=1' -metadata title='Preserved title' "$lyrics_test_dir/original.$ext"
        cp "$lyrics_test_dir/original.$ext" "$lyrics_test_dir/embedded.$ext"
        "$lyrics_test_dir/lyrics-regression" "$lyrics_test_dir/embedded.$ext" "$lyrics_test_dir"
        ffmpeg -v error -i "$lyrics_test_dir/original.$ext" -f s16le "$lyrics_test_dir/before-$ext.pcm"
        ffmpeg -v error -i "$lyrics_test_dir/embedded.$ext" -f s16le "$lyrics_test_dir/after-$ext.pcm"
        cmp "$lyrics_test_dir/before-$ext.pcm" "$lyrics_test_dir/after-$ext.pcm"
        ffprobe -v error -show_entries format_tags=title -of default=nw=1 "$lyrics_test_dir/embedded.$ext" | rg -q 'Preserved title'
    done
    echo 'PASS: independent MP3/FLAC decoder PCM equality and title preservation'
fi
