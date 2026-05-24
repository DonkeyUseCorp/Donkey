#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/dist/Donkey.app"
DMG_PATH="$ROOT_DIR/dist/Donkey.dmg"
DMG_RW_PATH="$ROOT_DIR/dist/Donkey-rw.dmg"
DMG_ROOT="$ROOT_DIR/dist/DonkeyInstaller"
RUNTIME_PACKAGE_DIR="$ROOT_DIR/dist/LocalRuntimePackages"
APP_VERSION="${DONKEY_APP_VERSION:-0.1.0}"
APP_BUILD="${DONKEY_APP_BUILD:-1}"
WEB_BASE_URL="${DONKEY_WEB_BASE_URL:-https://donkeyuse.com}"
BACKEND_BASE_URL="${DONKEY_BACKEND_URL:-$WEB_BASE_URL}"
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
DMG_BACKGROUND_SOURCE="$ROOT_DIR/scripts/assets/donkey-dmg-background.svg"
DMG_BACKGROUND_RENDERED="$ROOT_DIR/dist/donkey-dmg-background.png"
DMG_WINDOW_WIDTH=760
DMG_WINDOW_HEIGHT=480
DMG_WINDOW_LEFT=160
DMG_WINDOW_TOP=120
DMG_WINDOW_RIGHT=$((DMG_WINDOW_LEFT + DMG_WINDOW_WIDTH))
DMG_WINDOW_BOTTOM=$((DMG_WINDOW_TOP + DMG_WINDOW_HEIGHT))
DMG_APP_ICON_X=220
DMG_APP_ICON_Y=225
DMG_APPLICATIONS_ICON_X=540
DMG_APPLICATIONS_ICON_Y=225

render_dmg_background() {
  if [ ! -f "$DMG_BACKGROUND_SOURCE" ]; then
    echo "Missing DMG background image: $DMG_BACKGROUND_SOURCE" >&2
    exit 1
  fi
  if ! command -v magick >/dev/null 2>&1; then
    echo "ImageMagick is required to render $DMG_BACKGROUND_SOURCE for the Finder installer background." >&2
    exit 1
  fi

  mkdir -p "$(dirname "$DMG_BACKGROUND_RENDERED")"
  magick "$DMG_BACKGROUND_SOURCE" "PNG24:$DMG_BACKGROUND_RENDERED"
}

set_dmg_volume_icon() {
  local volume_dir="$1"

  if [ -f "$APP_ICON_SOURCE" ]; then
    cp "$APP_ICON_SOURCE" "$volume_dir/.VolumeIcon.icns"
    SetFile -t icns -c icnC "$volume_dir/.VolumeIcon.icns"
    SetFile -a V "$volume_dir/.VolumeIcon.icns"
    SetFile -a C "$volume_dir"
  fi
}

configure_dmg_window() {
  local mount_dir="$1"

  SetFile -a V "$mount_dir/.background" >/dev/null 2>&1 || true

  osascript <<APPLESCRIPT
tell application "Finder"
  set mountedFolder to POSIX file "$mount_dir" as alias
  set backgroundFile to POSIX file "$mount_dir/.background/donkey-dmg-background.png" as alias
  open mountedFolder
  delay 0.2
  set installerWindow to front Finder window
  set current view of installerWindow to icon view
  try
    set toolbar visible of installerWindow to false
  end try
  try
    set statusbar visible of installerWindow to false
  end try
  set bounds of installerWindow to {$DMG_WINDOW_LEFT, $DMG_WINDOW_TOP, $DMG_WINDOW_RIGHT, $DMG_WINDOW_BOTTOM}
  set theViewOptions to icon view options of installerWindow
  set arrangement of theViewOptions to not arranged
  set icon size of theViewOptions to 144
  set background picture of theViewOptions to backgroundFile
  set position of item "Donkey.app" of installerWindow to {$DMG_APP_ICON_X, $DMG_APP_ICON_Y}
  set position of item "Applications" of installerWindow to {$DMG_APPLICATIONS_ICON_X, $DMG_APPLICATIONS_ICON_Y}
  update mountedFolder without registering applications
  delay 1
  close installerWindow
end tell
APPLESCRIPT

  set_dmg_volume_icon "$mount_dir"
}

create_drag_to_applications_dmg() {
  local mount_dir
  local mounted=0

  render_dmg_background

  mount_dir="$(mktemp -d "${TMPDIR:-/tmp}/donkey-dmg.XXXXXX")"
  cleanup_dmg_mount() {
    trap - RETURN
    if [ "$mounted" = "1" ]; then
      hdiutil detach "$mount_dir" -force >/dev/null 2>&1 || true
    fi
    rm -rf "$mount_dir"
  }
  trap cleanup_dmg_mount RETURN

  rm -rf "$DMG_ROOT" "$DMG_PATH" "$DMG_RW_PATH"
  mkdir -p "$DMG_ROOT/.background"
  cp -R "$APP_DIR" "$DMG_ROOT/Donkey.app"
  ln -s /Applications "$DMG_ROOT/Applications"
  cp "$DMG_BACKGROUND_RENDERED" "$DMG_ROOT/.background/donkey-dmg-background.png"

  hdiutil create \
    -volname "Donkey" \
    -srcfolder "$DMG_ROOT" \
    -ov \
    -format UDRW \
    -fs HFS+ \
    "$DMG_RW_PATH" >/dev/null

  hdiutil attach "$DMG_RW_PATH" \
    -readwrite \
    -noverify \
    -noautoopen \
    -mountpoint "$mount_dir" >/dev/null
  mounted=1

  configure_dmg_window "$mount_dir"
  sync
  hdiutil detach "$mount_dir" >/dev/null
  mounted=0

  hdiutil convert "$DMG_RW_PATH" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -o "$DMG_PATH" >/dev/null

  rm -rf "$DMG_ROOT" "$DMG_RW_PATH"
}

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
  <key>DonkeyBackendURL</key>
  <string>$BACKEND_BASE_URL</string>
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

create_drag_to_applications_dmg

echo "Packaged $APP_DIR"
echo "Created drag-to-Applications disk image: $DMG_PATH"
echo "Open it with: open \"$APP_DIR\""
echo "Test the install flow with: open \"$DMG_PATH\""
echo "For Sparkle updates, package with DONKEY_SPARKLE_FEED_URL and DONKEY_SPARKLE_PUBLIC_ED_KEY."
