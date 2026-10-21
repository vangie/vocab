#!/bin/sh
# Render the activity rings offscreen to PNG (no screen capture needed): scripts/render-rings.sh [outdir]
set -e
cd "$(dirname "$0")/.."
swiftc -O -parse-as-library -o /tmp/render-rings Sources/Vocab/ActivityRings.swift scripts/render-rings-main.swift 2>&1 | grep -v warning || true
/tmp/render-rings "${1:-/tmp/rings}"
