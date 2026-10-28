#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $# != 3 ]]; then echo 'usage: prepare_music_transition_fixtures.sh TRACK_A TRACK_B OUTPUT_DIR' >&2; exit 2; fi
track_a="$1";track_b="$2";root="$3";work=$(mktemp -d /private/tmp/OngakuMusicSinc.XXXXXX)
trap 'rm -rf "$work"' EXIT
mkdir -p "$root/a" "$root/b"
ffmpeg -hide_banner -loglevel error -ss 25 -t 1.4 -i "$track_a" -ac 2 -ar 44100 -f f32le -y "$root/a/crest-44100.f32"
ffmpeg -hide_banner -loglevel error -ss 25 -t 1.4 -i "$track_b" -ac 2 -ar 44100 -f f32le -y "$root/b/crest-44100.f32"
python3 tests/sinc-benchmark/extract_fixture.py "$work/ShippingSinc.swift"
swiftc -parse-as-library -O -suppress-warnings -module-cache-path "$work/cache" "$work/ShippingSinc.swift" tests/CrestShippingSincFixture.swift -o "$work/sinc"
"$work/sinc" "$root/a"
"$work/sinc" "$root/b"
