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
APP_ICONSET_SOURCE="$BUILD_DIR/Sources/Donkey/Resources/Donkey.iconset"
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
  local volume_icon_source="$RESOURCES_DIR/Donkey.icns"

  if [ -f "$volume_icon_source" ]; then
    cp "$volume_icon_source" "$volume_dir/.VolumeIcon.icns"
    SetFile -t icns -c icnC "$volume_dir/.VolumeIcon.icns"
    SetFile -a V "$volume_dir/.VolumeIcon.icns"
    SetFile -a C "$volume_dir"
  fi
}

prepare_app_icon() {
  local destination="$RESOURCES_DIR/Donkey.icns"

  if [ -d "$APP_ICONSET_SOURCE" ]; then
    if ! command -v iconutil >/dev/null 2>&1; then
      echo "iconutil is required to package Donkey.app from $APP_ICONSET_SOURCE." >&2
      exit 1
    fi
    iconutil --convert icns --output "$destination" "$APP_ICONSET_SOURCE"
    return
  fi

  if [ -f "$APP_ICON_SOURCE" ]; then
    cp "$APP_ICON_SOURCE" "$destination"
    return
  fi

  echo "Missing app icon sources: $APP_ICONSET_SOURCE or $APP_ICON_SOURCE" >&2
  exit 1
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
  detach_dmg_mount() {
    local detach_target="$1"
    local attempt

    sync
    for attempt in 1 2 3; do
      if hdiutil detach "$detach_target" >/dev/null 2>&1; then
        return 0
      fi
      sleep "$attempt"
      sync
    done

    hdiutil detach "$detach_target" -force >/dev/null
  }
  cleanup_dmg_mount() {
    trap - RETURN
    if [ "$mounted" = "1" ]; then
      detach_dmg_mount "$mount_dir" >/dev/null 2>&1 || true
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
  detach_dmg_mount "$mount_dir"
  mounted=0

  hdiutil convert "$DMG_RW_PATH" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -o "$DMG_PATH" >/dev/null

  rm -rf "$DMG_ROOT" "$DMG_RW_PATH"
}

# --- Code signing + notarization ----------------------------------------------------------------
# DONKEY_APP_SIGN_IDENTITY selects how the app is signed:
#   "-" (default)        ad-hoc — runs locally, NOT distributable (the dev/local path).
#   "Developer ID ..."   real identity + hardened runtime + secure timestamp, then notarized + stapled
#                        (the release path; the release workflow imports the cert and sets this).
APP_SIGN_IDENTITY="${DONKEY_APP_SIGN_IDENTITY:--}"
APP_ENTITLEMENTS="${DONKEY_APP_ENTITLEMENTS:-$ROOT_DIR/scripts/assets/donkey.entitlements}"

# Submit an artifact (app zip or DMG) to Apple's notary service and wait for the verdict. notarytool
# exits non-zero if the bundle is rejected, so a bad signature fails the build here.
notarytool_submit() {
  local artifact="$1"
  if [ -f "${DONKEY_NOTARY_KEY_P8:-/nonexistent}" ] && [ -n "${DONKEY_NOTARY_KEY_ID:-}" ] && [ -n "${DONKEY_NOTARY_ISSUER_ID:-}" ]; then
    xcrun notarytool submit "$artifact" \
      --key "$DONKEY_NOTARY_KEY_P8" --key-id "$DONKEY_NOTARY_KEY_ID" --issuer "$DONKEY_NOTARY_ISSUER_ID" --wait
  elif [ -n "${DONKEY_NOTARY_APPLE_ID:-}" ] && [ -n "${DONKEY_NOTARY_TEAM_ID:-}" ] && [ -n "${DONKEY_NOTARY_PASSWORD:-}" ]; then
    xcrun notarytool submit "$artifact" \
      --apple-id "$DONKEY_NOTARY_APPLE_ID" --team-id "$DONKEY_NOTARY_TEAM_ID" --password "$DONKEY_NOTARY_PASSWORD" --wait
  else
    echo "FATAL: app signed with Developer ID but no notary credentials provided." >&2
    exit 1
  fi
}

# Sign the app bundle. Ad-hoc when no identity; otherwise Developer ID + hardened runtime, signed
# inside-out (Apple discourages --deep for notarization). Sparkle's nested XPC services and Updater.app
# are signed first, preserving their own (sandbox) entitlements, then the framework, then the app — which
# carries the Apple Events entitlement it needs to keep automating other apps under the hardened runtime.
sign_app() {
  if [ "$APP_SIGN_IDENTITY" = "-" ]; then
    codesign --force --deep --sign - "$APP_DIR" >/dev/null
    echo "Ad-hoc signed $APP_DIR (not for distribution)."
    return 0
  fi
  local base=(--force --options runtime --timestamp --sign "$APP_SIGN_IDENTITY")
  # Target the signing keychain explicitly when the release workflow points us at one. Relying on the
  # user keychain search list is unreliable here: the keychain is imported in a separate CI step, and
  # that search-list state doesn't dependably reach codesign in this step (hence "no identity found"
  # even though the identity imported fine).
  [ -n "${DONKEY_SIGN_KEYCHAIN:-}" ] && base=(--keychain "$DONKEY_SIGN_KEYCHAIN" "${base[@]}")
  local sparkle="$FRAMEWORKS_DIR/Sparkle.framework"
  if [ -d "$sparkle" ]; then
    # Versions/Current keeps this agnostic to Sparkle's version letter.
    local cur="$sparkle/Versions/Current" item
    for item in \
      "$cur/XPCServices/Downloader.xpc" \
      "$cur/XPCServices/Installer.xpc" \
      "$cur/Autoupdate" \
      "$cur/Updater.app"; do
      [ -e "$item" ] && codesign "${base[@]}" --preserve-metadata=entitlements "$item"
    done
    codesign "${base[@]}" "$sparkle"
  fi
  local f
  while IFS= read -r -d '' f; do codesign "${base[@]}" "$f"; done \
    < <(find "$FRAMEWORKS_DIR" -type f -name "*.dylib" -print0 2>/dev/null)
  local ent=()
  [ -f "$APP_ENTITLEMENTS" ] && ent=(--entitlements "$APP_ENTITLEMENTS")
  codesign "${base[@]}" "${ent[@]}" "$APP_DIR"
  echo "Developer ID signed $APP_DIR with '$APP_SIGN_IDENTITY' (hardened runtime)."
}

# Notarize + staple the signed app so it launches cleanly (even offline) once dragged out of the DMG.
notarize_app() {
  [ "$APP_SIGN_IDENTITY" = "-" ] && return 0
  local zip="$ROOT_DIR/dist/Donkey-app-notarize.zip"
  rm -f "$zip"
  /usr/bin/ditto -c -k --keepParent "$APP_DIR" "$zip"
  echo "Notarizing the app ..."
  notarytool_submit "$zip"
  xcrun stapler staple "$APP_DIR"
  rm -f "$zip"
  echo "Notarized and stapled $APP_DIR."
}

# Sign, notarize, and staple the DMG itself (disk images can be stapled, unlike loose binaries), so it
# opens without a Gatekeeper prompt.
notarize_dmg() {
  [ "$APP_SIGN_IDENTITY" = "-" ] && return 0
  local dmg_sign=(--force --timestamp --sign "$APP_SIGN_IDENTITY")
  [ -n "${DONKEY_SIGN_KEYCHAIN:-}" ] && dmg_sign=(--keychain "$DONKEY_SIGN_KEYCHAIN" "${dmg_sign[@]}")
  codesign "${dmg_sign[@]}" "$DMG_PATH"
  echo "Notarizing the disk image ..."
  notarytool_submit "$DMG_PATH"
  xcrun stapler staple "$DMG_PATH"
  echo "Notarized and stapled $DMG_PATH."
}

mkdir -p "$CACHE_DIR/clang" "$CACHE_DIR/swiftpm" "$CACHE_DIR/home"
export CLANG_MODULE_CACHE_PATH="$CACHE_DIR/clang"
export SWIFTPM_CACHE_PATH="$CACHE_DIR/swiftpm"
export HOME="$CACHE_DIR/home"

cd "$BUILD_DIR"
echo "Compiling Donkey for Mac ..."
swift build -c release --product Donkey

# The bundled command-line tools (yt-dlp, ffmpeg, qpdf, exiftool, ...) are NOT baked into
# the app: the shipped app stays small and downloads a prebuilt, self-contained arm64 tools
# bundle on first run (see BundledToolsInstaller + bundled-tools.json). The release pipeline
# that *produces and publishes* that artifact is scripts/publish-bundled-tools.sh.
#
# As an offline/airgapped escape hatch, point DONKEY_TOOLS_DIR at a prebuilt directory to
# bake it into the app anyway; otherwise this stages nothing and the app self-installs.
stage_bundled_tools() {
  local source_dir="${DONKEY_TOOLS_DIR:-}"
  if [ -z "$source_dir" ]; then
    echo "Not baking tools into the app; it downloads them on first run."
    return 0
  fi
  if [ ! -d "$source_dir" ]; then
    echo "DONKEY_TOOLS_DIR=$source_dir does not exist." >&2
    exit 1
  fi
  local dest_dir="$RESOURCES_DIR/donkey-tools"
  rm -rf "$dest_dir"
  mkdir -p "$dest_dir"
  cp -R "$source_dir/." "$dest_dir/"
  # Sign each baked tool with the app's identity (Developer ID + hardened runtime for a release,
  # ad-hoc otherwise) so a notarized build doesn't trip on an unsigned Mach-O; a non-Mach-O script
  # (e.g. exiftool) just no-ops here.
  local sopts=(--force --sign "$APP_SIGN_IDENTITY")
  [ "$APP_SIGN_IDENTITY" != "-" ] && sopts+=(--options runtime --timestamp)
  [ -n "${DONKEY_SIGN_KEYCHAIN:-}" ] && sopts+=(--keychain "$DONKEY_SIGN_KEYCHAIN")
  find "$dest_dir" -type f -perm -u+x -print0 | while IFS= read -r -d '' tool; do
    chmod +x "$tool"
    codesign "${sopts[@]}" "$tool" >/dev/null 2>&1 || true
  done
  echo "Baked bundled tools from $source_dir into $dest_dir (offline override)."
}

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
find "$APP_DIR" -name dev-overlay.json -type f -delete
prepare_app_icon

SPARKLE_FRAMEWORK="$(find "$BUILD_DIR/.build" -path "*/release/Sparkle.framework" -type d | head -n 1 || true)"
if [ -z "$SPARKLE_FRAMEWORK" ]; then
  SPARKLE_FRAMEWORK="$(find "$BUILD_DIR/.build" -path "*/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework" -type d | head -n 1 || true)"
fi
if [ -n "$SPARKLE_FRAMEWORK" ]; then
  cp -R "$SPARKLE_FRAMEWORK" "$FRAMEWORKS_DIR/"
fi

stage_bundled_tools

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
  <string>com.donkeyuse.Donkey</string>
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
      <string>com.donkeyuse.Donkey.auth</string>
      <key>CFBundleURLSchemes</key>
      <array>
        <string>$AUTH_CALLBACK_SCHEME</string>
      </array>
    </dict>
  </array>
  <key>NSMicrophoneUsageDescription</key>
  <string>Donkey uses the microphone for user-requested voice input.</string>
  <key>NSSpeechRecognitionUsageDescription</key>
  <string>Donkey transcribes your voice input on-device to turn it into a command.</string>
  <key>NSScreenCaptureUsageDescription</key>
  <string>Donkey captures bounded screenshots for user-requested app context.</string>
  <key>NSAppleEventsUsageDescription</key>
  <string>Donkey uses local app automation only for user-requested actions.</string>
  <key>NSDesktopFolderUsageDescription</key>
  <string>Donkey may search Desktop files only when you ask it to find or open a local item.</string>
  <key>NSDocumentsFolderUsageDescription</key>
  <string>Donkey may search Documents files only when you ask it to find or open a local item.</string>
  <key>NSDownloadsFolderUsageDescription</key>
  <string>Donkey may search Downloads files only when you ask it to find or open a local item.</string>
  <key>NSAppleMusicUsageDescription</key>
  <string>Donkey plays Apple Music natively when you ask for music.</string>
$SPARKLE_PLIST_KEYS
</dict>
</plist>
PLIST

sign_app
notarize_app

create_drag_to_applications_dmg
notarize_dmg

echo "Packaged $APP_DIR"
echo "Created drag-to-Applications disk image: $DMG_PATH"
echo "Open it with: open \"$APP_DIR\""
echo "Test the install flow with: open \"$DMG_PATH\""
echo "For Sparkle updates, package with DONKEY_SPARKLE_FEED_URL and DONKEY_SPARKLE_PUBLIC_ED_KEY."
