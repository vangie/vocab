#!/bin/bash
# Build Vocab.app into ./build (release by default). Usage: scripts/bundle.sh [debug|release]
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-release}"
swift build -c "$CONFIG" --product Vocab
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Vocab"
FINAL="build/Vocab.app"
# Assemble in a staging folder, then swap it in.
APP="build/.staging/Vocab.app"
rm -rf build/.staging
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Vocab"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/" || true
# Set VOCAB_SIGN_IDENTITY to a stable code-signing identity to keep the Accessibility
# grant across rebuilds. Falls back to an ad-hoc signature,
# in which case macOS may ask for Accessibility permission again after each rebuild.
# (Auto-picking a keychain identity is deliberately avoided: an Apple Development
# certificate without a matching provisioning setup can make LaunchServices refuse to launch.)
IDENTITY="${VOCAB_SIGN_IDENTITY:-}"
if [ -n "$IDENTITY" ]; then
  codesign --force --sign "$IDENTITY" --timestamp=none "$APP"
  echo "Signed with: $IDENTITY"
else
  codesign --force --sign - --timestamp=none "$APP"
  echo "Signed ad-hoc"
fi
rm -rf "$FINAL"
mv "$APP" "$FINAL"
rmdir build/.staging 2>/dev/null || true
echo "Built $FINAL"
echo "Note: the first launch of a freshly signed build can take a minute while macOS scans it."
