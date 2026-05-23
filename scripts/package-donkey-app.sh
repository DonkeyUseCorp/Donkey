#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/dist/Donkey.app"
DMG_PATH="$ROOT_DIR/dist/Donkey.dmg"
DMG_ROOT="$ROOT_DIR/dist/DonkeyInstaller"
RUNTIME_PACKAGE_DIR="$ROOT_DIR/dist/LocalRuntimePackages"
APP_VERSION="${DONKEY_APP_VERSION:-0.1.0}"
APP_BUILD="${DONKEY_APP_BUILD:-1}"
WEB_BASE_URL="${DONKEY_WEB_BASE_URL:-https://donkeyuse.com}"
AUTH_CALLBACK_SCHEME="${DONKEY_AUTH_CALLBACK_SCHEME:-donkey}"
SPARKLE_FEED_URL="${DONKEY_SPARKLE_FEED_URL:-}"
SPARKLE_PUBLIC_ED_KEY="${DONKEY_SPARKLE_PUBLIC_ED_KEY:-}"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
FRAMEWORKS_DIR="$CONTENTS_DIR/Frameworks"
BUILD_DIR="$ROOT_DIR/apps/Donkey"
EXECUTABLE="$BUILD_DIR/.build/release/Donkey"
CACHE_DIR="$BUILD_DIR/.build/package-cache"
APP_ICON_SOURCE="$BUILD_DIR/Sources/Donkey/Resources/Donkey.icns"

mkdir -p "$CACHE_DIR/clang" "$CACHE_DIR/swiftpm" "$CACHE_DIR/home"
export CLANG_MODULE_CACHE_PATH="$CACHE_DIR/clang"
export SWIFTPM_CACHE_PATH="$CACHE_DIR/swiftpm"
export HOME="$CACHE_DIR/home"

cd "$BUILD_DIR"
echo "Compiling Donkey for Mac ..."
swift build -c release --product Donkey

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$FRAMEWORKS_DIR"
cp "$EXECUTABLE" "$MACOS_DIR/Donkey"
if ! otool -l "$MACOS_DIR/Donkey" | grep -q "@executable_path/../Frameworks"; then
  if ! command -v install_name_tool >/dev/null 2>&1; then
    echo "install_name_tool is required to package Donkey.app with embedded frameworks." >&2
    exit 1
  fi
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$MACOS_DIR/Donkey"
fi

rm -rf "$RUNTIME_PACKAGE_DIR"

RESOURCE_BUNDLE="$(find "$BUILD_DIR/.build" -path "*/release/Donkey_Donkey.bundle" -type d | head -n 1 || true)"
if [ -n "$RESOURCE_BUNDLE" ]; then
  cp -R "$RESOURCE_BUNDLE" "$RESOURCES_DIR/"
elif [ -d "$BUILD_DIR/.build/release/Donkey_Donkey.resources" ]; then
  cp -R "$BUILD_DIR/.build/release/Donkey_Donkey.resources/." "$RESOURCES_DIR/"
fi
if [ -f "$APP_ICON_SOURCE" ]; then
  cp "$APP_ICON_SOURCE" "$RESOURCES_DIR/Donkey.icns"
fi

SPARKLE_FRAMEWORK="$(find "$BUILD_DIR/.build" -path "*/release/Sparkle.framework" -type d | head -n 1 || true)"
if [ -z "$SPARKLE_FRAMEWORK" ]; then
  SPARKLE_FRAMEWORK="$(find "$BUILD_DIR/.build" -path "*/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework" -type d | head -n 1 || true)"
fi
if [ -n "$SPARKLE_FRAMEWORK" ]; then
  cp -R "$SPARKLE_FRAMEWORK" "$FRAMEWORKS_DIR/"
fi

SPARKLE_PLIST_KEYS=""
if [ -n "$SPARKLE_FEED_URL" ] && [ -n "$SPARKLE_PUBLIC_ED_KEY" ]; then
  SPARKLE_PLIST_KEYS="  <key>SUEnableInstallerLauncherService</key>
  <true/>
  <key>SUEnableDownloaderService</key>
  <true/>
  <key>SUFeedURL</key>
  <string>$SPARKLE_FEED_URL</string>
  <key>SUPublicEDKey</key>
  <string>$SPARKLE_PUBLIC_ED_KEY</string>"
fi

cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>Donkey</string>
  <key>CFBundleIdentifier</key>
  <string>ai.donkey.Donkey</string>
  <key>CFBundleName</key>
  <string>Donkey</string>
  <key>CFBundleDisplayName</key>
  <string>Donkey</string>
  <key>CFBundleIconFile</key>
  <string>Donkey.icns</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$APP_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$APP_BUILD</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>DonkeyWebBaseURL</key>
  <string>$WEB_BASE_URL</string>
  <key>DonkeyAuthCallbackScheme</key>
  <string>$AUTH_CALLBACK_SCHEME</string>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key>
      <string>ai.donkey.Donkey.auth</string>
      <key>CFBundleURLSchemes</key>
      <array>
        <string>$AUTH_CALLBACK_SCHEME</string>
      </array>
    </dict>
  </array>
  <key>NSMicrophoneUsageDescription</key>
  <string>Donkey uses the microphone for user-requested voice input.</string>
  <key>NSScreenCaptureUsageDescription</key>
  <string>Donkey captures bounded screenshots for user-requested app context.</string>
  <key>NSAppleEventsUsageDescription</key>
  <string>Donkey uses local app automation only for user-requested actions.</string>
$SPARKLE_PLIST_KEYS
</dict>
</plist>
PLIST

if command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - "$APP_DIR" >/dev/null
fi

rm -rf "$DMG_ROOT" "$DMG_PATH"
mkdir -p "$DMG_ROOT"
cp -R "$APP_DIR" "$DMG_ROOT/Donkey.app"
ln -s /Applications "$DMG_ROOT/Applications"
hdiutil create \
  -volname "Donkey" \
  -srcfolder "$DMG_ROOT" \
  -ov \
  -format UDZO \
  "$DMG_PATH" >/dev/null
rm -rf "$DMG_ROOT"

echo "Packaged $APP_DIR"
echo "Created drag-to-Applications disk image: $DMG_PATH"
echo "Open it with: open \"$APP_DIR\""
echo "Test the install flow with: open \"$DMG_PATH\""
echo "For Sparkle updates, package with DONKEY_SPARKLE_FEED_URL and DONKEY_SPARKLE_PUBLIC_ED_KEY."
