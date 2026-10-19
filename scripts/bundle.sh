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
# Local, untracked icon override: Local/AppIcon.png (1024px) wins over Resources/AppIcon.icns.
if [ -f Local/AppIcon.png ]; then
  SET="$(mktemp -d)/AppIcon.iconset"; mkdir -p "$SET"
  for s in 16 32 128 256 512; do
    sips -z $s $s Local/AppIcon.png --out "$SET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) Local/AppIcon.png --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$SET" -o "$APP/Contents/Resources/AppIcon.icns"
  echo "Icon: Local/AppIcon.png (local override)"
elif [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/"
fi
# Set VOCAB_SIGN_IDENTITY to a stable code-signing identity to keep the Accessibility
# grant across rebuilds. Falls back to an ad-hoc signature,
# in which case macOS may ask for Accessibility permission again after each rebuild.
# (Auto-picking a keychain identity is deliberately avoided: an Apple Development
# certificate without a matching provisioning setup can make LaunchServices refuse to launch.)
IDENTITY="${VOCAB_SIGN_IDENTITY:-}"
SIGNDIR="$HOME/Library/Application Support/Vocab/signing"
KC="$SIGNDIR/vocab-signing.keychain-db"
KCARGS=()
# Local self-signed identity created by scripts/setup-signing.sh (dedicated keychain, no prompts).
if [ -z "$IDENTITY" ] && [ -f "$KC" ] && [ -f "$SIGNDIR/pass" ]; then
  security unlock-keychain -p "$(cat "$SIGNDIR/pass")" "$KC" >/dev/null 2>&1 || true
  IDENTITY="Vocab Local Signing"
  KCARGS=(--keychain "$KC")
fi
if [ -n "$IDENTITY" ]; then
  codesign --force --sign "$IDENTITY" ${KCARGS[@]+"${KCARGS[@]}"} --timestamp=none "$APP"
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
