#!/usr/bin/env bash
# Builds Notchling.app and packs it into dist/Notchling-<version>.dmg — the file you give to friends.
# Run on a Mac with Xcode 26+ (Xcode 16 also works, minus the Apple Intelligence brain):
#   ./scripts/build-installer.sh
# No Mac/Xcode? Push to GitHub and use the "Build installer" Action instead.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-1.0.0}"
BUILD="$ROOT/build"
DIST="$ROOT/dist"
APP_NAME="Notchling"

command -v xcodebuild >/dev/null || { echo "❌ Xcode is required (install it from the App Store, open it once)."; exit 1; }
if ! command -v xcodegen >/dev/null; then
  if command -v brew >/dev/null; then
    echo "📦 Installing XcodeGen with Homebrew…"; brew install xcodegen
  else
    echo "❌ XcodeGen is required. Install Homebrew (https://brew.sh) then run: brew install xcodegen"; exit 1
  fi
fi

echo "🛠  Generating Xcode project…"
cd "$ROOT/Notchling"
xcodegen generate --quiet

# Apple's on-device AI (FoundationModels) only exists in the macOS 26 SDK. Weak-link it so the
# app still launches on macOS 14/15, where Notchling simply falls back to Gemini.
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
EXTRA=()
if [ -d "$SDK_PATH/System/Library/Frameworks/FoundationModels.framework" ]; then
  echo "🧠 Apple Intelligence brain: included"
  EXTRA+=("OTHER_LDFLAGS=-weak_framework FoundationModels")
else
  echo "🧠 Apple Intelligence brain: skipped (needs Xcode 26 / macOS 26 SDK)"
fi

echo "🔨 Building $APP_NAME $VERSION (Apple Silicon + Intel)…"
rm -rf "$BUILD" && mkdir -p "$BUILD" "$DIST"
xcodebuild \
  -project "$APP_NAME.xcodeproj" \
  -scheme "$APP_NAME" \
  -configuration Release \
  -derivedDataPath "$BUILD/DerivedData" \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  MARKETING_VERSION="$VERSION" \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO \
  ${EXTRA[@]+"${EXTRA[@]}"} \
  -quiet build

APP="$BUILD/DerivedData/Build/Products/Release/$APP_NAME.app"
[ -d "$APP" ] || { echo "❌ Build failed: $APP not found"; exit 1; }

echo "✍️  Ad-hoc signing…"
codesign --force --deep --sign - "$APP"

echo "💿 Creating disk image…"
STAGE="$BUILD/dmg"
rm -rf "$STAGE" && mkdir -p "$STAGE"
ditto "$APP" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"
cp "$ROOT/installer/Install Notchling.command" "$STAGE/"
cp "$ROOT/installer/READ ME FIRST.txt" "$STAGE/"
chmod +x "$STAGE/Install Notchling.command"

DMG="$DIST/$APP_NAME-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null

echo ""
echo "✅ Installer ready: $DMG"
echo "   Send that .dmg to your friends (AirDrop, Google Drive, USB…)."
