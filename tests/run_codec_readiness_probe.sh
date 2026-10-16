#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
codec_dir=$(mktemp -d /private/tmp/OngakuCodecs.XXXXXX)
trap 'rm -rf "$codec_dir"' EXIT
swiftc -parse-as-library -O -module-cache-path "$codec_dir/module-cache" tests/CodecReadinessProbe.swift -o "$codec_dir/probe"
python3 tests/codec_readiness_probe.py "$codec_dir" "${1:-/private/tmp/OngakuCodecReadiness.json}"
