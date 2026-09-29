#!/bin/bash
# Double-click me to install Notchling. (If macOS blocks me, see "READ ME FIRST.txt".)
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$DIR/Notchling.app"
DEST="/Applications"
[ -w "$DEST" ] || { DEST="$HOME/Applications"; mkdir -p "$DEST"; }

echo "🌱 Installing Notchling into $DEST …"
if pgrep -x Notchling >/dev/null 2>&1; then
  osascript -e 'quit app "Notchling"' >/dev/null 2>&1 || true
  sleep 1
fi
rm -rf "$DEST/Notchling.app"
ditto "$SRC" "$DEST/Notchling.app"
# Remove the "downloaded from the internet" flag so macOS lets the app open.
xattr -dr com.apple.quarantine "$DEST/Notchling.app" 2>/dev/null || true
open "$DEST/Notchling.app"
echo ""
echo "✅ Done! Look at the top-middle of your screen — your egg is about to hatch 🥚"
echo "   (You can close this window.)"
