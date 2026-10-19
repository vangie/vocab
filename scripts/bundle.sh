#!/bin/bash
# Build Vocab.app into ./build (release by default). Usage: scripts/bundle.sh [debug|release]
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-release}"
swift build -c "$CONFIG" --product Vocab
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Vocab"
APP="build/Vocab.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Vocab"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/" || true
# Ad-hoc signature (no developer account needed). Re-signing changes the identity,
# so macOS may ask for Accessibility permission again after a rebuild.
codesign --force --sign - --timestamp=none "$APP"
echo "Built $APP"
