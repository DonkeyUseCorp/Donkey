#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/apps/Donkey"
LOG_SCRIPT="$ROOT_DIR/scripts/tail-donkey-logs.sh"
BUILD_PRODUCTS_DIR="$APP_DIR/.build/debug"
DONKEY_BIN="$BUILD_PRODUCTS_DIR/Donkey"
DEV_BUNDLE_IDENTIFIER="${DONKEY_DEV_BUNDLE_IDENTIFIER:-ai.donkey.Donkey.dev}"
DEV_DISPLAY_NAME="${DONKEY_DEV_DISPLAY_NAME:-Donkey Dev}"
DEV_EXECUTABLE_NAME="${DONKEY_DEV_EXECUTABLE_NAME:-$DEV_DISPLAY_NAME}"
DEV_APP_DIR="$BUILD_PRODUCTS_DIR/$DEV_DISPLAY_NAME.app"
CACHE_DIR="$APP_DIR/.build/dev-script-cache"
CACHE_CLANG_DIR="$CACHE_DIR/clang"
CACHE_SWIFTPM_DIR="$CACHE_DIR/swiftpm"
CACHE_HOME_DIR="$CACHE_DIR/home"
CONTENTS_DIR="$DEV_APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
FRAMEWORKS_DIR="$CONTENTS_DIR/Frameworks"
APP_ICON_SOURCE="$APP_DIR/Sources/Donkey/Resources/Donkey.icns"
APP_ICONSET_SOURCE="$APP_DIR/Sources/Donkey/Resources/Donkey.iconset"
AUTH_CALLBACK_SCHEME="${DONKEY_AUTH_CALLBACK_SCHEME:-donkey}"
LAUNCH_APP="${DONKEY_LAUNCH_APP:-1}"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
SITE_PID=""
SITE_LOG="${DONKEY_SITE_LOG:-${TMPDIR:-/tmp}/donkey-site-dev.log}"
LOG_PID=""

export DONKEY_WEB_BASE_URL="${DONKEY_WEB_BASE_URL:-http://localhost:3000}"

stop_running_donkey_apps() {
  killall Donkey >/dev/null 2>&1 || true
  if [ "$DEV_DISPLAY_NAME" != "Donkey" ]; then
    killall "$DEV_DISPLAY_NAME" >/dev/null 2>&1 || true
  fi
  killall DonkeyUIUnderstandingSidecar >/dev/null 2>&1 || true

  if command -v pkill >/dev/null 2>&1; then
    pkill -f '/Donkey\.app/Contents/MacOS/Donkey([[:space:]]|$)' >/dev/null 2>&1 || true
    pkill -f '/Donkey Dev\.app/Contents/MacOS/Donkey([[:space:]]|$)' >/dev/null 2>&1 || true
    pkill -f '/Donkey Dev\.app/Contents/MacOS/Donkey Dev([[:space:]]|$)' >/dev/null 2>&1 || true
  fi
}

cleanup_child_processes() {
  if [ "$LAUNCH_APP" != "0" ] && [ "${DONKEY_KEEP_APP_ON_EXIT:-0}" != "1" ]; then
    stop_running_donkey_apps
  fi
  if [ -n "$LOG_PID" ] && kill -0 "$LOG_PID" >/dev/null 2>&1; then
    kill "$LOG_PID" >/dev/null 2>&1 || true
    wait "$LOG_PID" >/dev/null 2>&1 || true
  fi
  if [ -n "$SITE_PID" ] && kill -0 "$SITE_PID" >/dev/null 2>&1; then
    kill "$SITE_PID" >/dev/null 2>&1 || true
    wait "$SITE_PID" >/dev/null 2>&1 || true
  fi
}

cleanup_on_exit() {
  local exit_code=$?
  trap - EXIT INT TERM HUP
  cleanup_child_processes
  exit "$exit_code"
}

cleanup_on_signal() {
  local exit_code="$1"
  trap - EXIT INT TERM HUP
  cleanup_child_processes
  exit "$exit_code"
}

start_logger() {
  if [ "${DONKEY_TAIL_LOGS:-1}" = "0" ]; then
    echo "Skipping Donkey log tail because DONKEY_TAIL_LOGS=0."
    return
  fi

  if [ ! -x "$LOG_SCRIPT" ]; then
    echo "Skipping Donkey log tail because $LOG_SCRIPT is not executable." >&2
    return
  fi

  local log_args=()
  log_args+=(--process "$DEV_EXECUTABLE_NAME")
  if [ "${DONKEY_LOG_ERRORS_ONLY:-0}" = "1" ]; then
    log_args+=(--errors)
  fi
  if [ "${DONKEY_LOG_DEBUG:-0}" = "1" ]; then
    log_args+=(--debug)
  fi
  if [ -n "${DONKEY_LOG_CONTAINS:-}" ]; then
    log_args+=(--contains "$DONKEY_LOG_CONTAINS")
  fi
  if [ "${DONKEY_LOG_ALL:-0}" != "1" ]; then
    log_args+=(--subsystem "${DONKEY_LOG_SUBSYSTEM:-com.donkey.app}")
  elif [ -n "${DONKEY_LOG_SUBSYSTEM:-}" ]; then
    log_args+=(--subsystem "$DONKEY_LOG_SUBSYSTEM")
  fi

  echo "Tailing Donkey logs..."
  if [ "${#log_args[@]}" -eq 0 ]; then
    "$LOG_SCRIPT" &
  else
    "$LOG_SCRIPT" "${log_args[@]}" &
  fi
  LOG_PID="$!"
}

print_dev_overlay_status() {
  local overlay_config="$APP_DIR/dev-overlay.json"
  if [ ! -f "$overlay_config" ]; then
    echo "Dev overlay config: missing at $overlay_config"
    return
  fi

  local summary
  summary="$(
    python3 - "$overlay_config" <<'PY' 2>/dev/null || true
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    config = json.load(handle)

print(
    "enabled={enabled} mode={mode} cadenceSeconds={cadence} "
    "screenScope={scope} minConfidence={confidence}".format(
        enabled=config.get("enabled", False),
        mode=config.get("mode", "donkeyVision"),
        cadence=config.get("cadenceSeconds", 1.0),
        scope=config.get("screenScope", "main"),
        confidence=config.get("minConfidence", 0.25),
    )
)
PY
  )"

  if [ -n "$summary" ]; then
    echo "Dev overlay config: $summary"
  else
    echo "Dev overlay config: invalid JSON at $overlay_config"
  fi
}

is_local_web_base_url() {
  case "$DONKEY_WEB_BASE_URL" in
    http://localhost|http://localhost:*|http://127.0.0.1|http://127.0.0.1:*|http://[::1]|http://[::1]:*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

site_health_url() {
  printf '%s/api/health' "${DONKEY_WEB_BASE_URL%/}"
}

site_is_running() {
  command -v curl >/dev/null 2>&1 &&
    curl --silent --fail --max-time 1 "$(site_health_url)" >/dev/null 2>&1
}

ensure_site_server() {
  if [ "${DONKEY_START_SITE:-1}" = "0" ]; then
    echo "Skipping site dev server because DONKEY_START_SITE=0."
    return
  fi

  if ! is_local_web_base_url; then
    echo "Skipping site dev server because DONKEY_WEB_BASE_URL is not local: $DONKEY_WEB_BASE_URL"
    return
  fi

  if site_is_running; then
    echo "Site dev server is already running at $DONKEY_WEB_BASE_URL."
    return
  fi

  if [ ! -d "$ROOT_DIR/site" ]; then
    echo "Missing site directory at $ROOT_DIR/site." >&2
    exit 1
  fi

  if ! command -v npm >/dev/null 2>&1; then
    echo "npm is required to start the local site dev server." >&2
    exit 1
  fi

  echo "Starting site dev server at $DONKEY_WEB_BASE_URL ..."
  (
    cd "$ROOT_DIR/site"
    npm run dev
  ) >"$SITE_LOG" 2>&1 &
  SITE_PID="$!"

  local wait_seconds="${DONKEY_SITE_WAIT_SECONDS:-30}"
  local elapsed=0
  while [ "$elapsed" -lt "$wait_seconds" ]; do
    if site_is_running; then
      echo "Site dev server is ready."
      return
    fi

    if ! kill -0 "$SITE_PID" >/dev/null 2>&1; then
      echo "Site dev server exited before becoming ready. Log: $SITE_LOG" >&2
      tail -n 60 "$SITE_LOG" >&2 || true
      exit 1
    fi

    sleep 1
    elapsed=$((elapsed + 1))
  done

  echo "Timed out waiting for the site dev server. Log: $SITE_LOG" >&2
  tail -n 60 "$SITE_LOG" >&2 || true
  exit 1
}

xml_escape() {
  printf '%s' "$1" |
    sed \
      -e 's/&/\&amp;/g' \
      -e 's/</\&lt;/g' \
      -e 's/>/\&gt;/g' \
      -e 's/"/\&quot;/g' \
      -e "s/'/\&apos;/g"
}

resolve_codesign_identity() {
  if [ -n "${DONKEY_CODESIGN_IDENTITY:-}" ]; then
    printf '%s\n' "$DONKEY_CODESIGN_IDENTITY"
    return
  fi

  if command -v security >/dev/null 2>&1; then
    local identity
    identity="$(
      security find-identity -v -p codesigning 2>/dev/null |
        awk -F '"' '/Apple Development/ { print $2; exit }'
    )"
    if [ -n "$identity" ]; then
      printf '%s\n' "$identity"
      return
    fi
  fi

  printf '%s\n' "-"
}

prepare_app_icon() {
  local destination="$RESOURCES_DIR/Donkey.icns"

  if [ -f "$APP_ICON_SOURCE" ]; then
    cp "$APP_ICON_SOURCE" "$destination"
    return
  fi

  if [ -d "$APP_ICONSET_SOURCE" ]; then
    if ! command -v iconutil >/dev/null 2>&1; then
      echo "iconutil is required to package Donkey.app from $APP_ICONSET_SOURCE." >&2
      exit 1
    fi
    iconutil --convert icns --output "$destination" "$APP_ICONSET_SOURCE"
    return
  fi

  echo "Missing app icon sources: $APP_ICON_SOURCE or $APP_ICONSET_SOURCE" >&2
  exit 1
}

write_info_plist() {
  local escaped_web_base_url
  local escaped_callback_scheme
  local escaped_bundle_identifier
  local escaped_display_name
  local escaped_executable_name
  escaped_web_base_url="$(xml_escape "$DONKEY_WEB_BASE_URL")"
  escaped_callback_scheme="$(xml_escape "$AUTH_CALLBACK_SCHEME")"
  escaped_bundle_identifier="$(xml_escape "$DEV_BUNDLE_IDENTIFIER")"
  escaped_display_name="$(xml_escape "$DEV_DISPLAY_NAME")"
  escaped_executable_name="$(xml_escape "$DEV_EXECUTABLE_NAME")"

  cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$escaped_executable_name</string>
  <key>CFBundleIdentifier</key>
  <string>$escaped_bundle_identifier</string>
  <key>CFBundleName</key>
  <string>$escaped_display_name</string>
  <key>CFBundleDisplayName</key>
  <string>$escaped_display_name</string>
  <key>CFBundleIconFile</key>
  <string>Donkey.icns</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0-dev</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>DonkeyWebBaseURL</key>
  <string>$escaped_web_base_url</string>
  <key>DonkeyAuthCallbackScheme</key>
  <string>$escaped_callback_scheme</string>
  <key>DonkeyDevOverlayConfigPath</key>
  <string>$APP_DIR/dev-overlay.json</string>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key>
      <string>$escaped_bundle_identifier.auth</string>
      <key>CFBundleURLSchemes</key>
      <array>
        <string>$escaped_callback_scheme</string>
      </array>
    </dict>
  </array>
  <key>NSMicrophoneUsageDescription</key>
  <string>Donkey uses the microphone for user-requested voice input.</string>
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
</dict>
</plist>
PLIST
}

create_debug_app_bundle() {
  local resource_bundle
  local sparkle_framework
  local codesign_identity

  rm -rf "$DEV_APP_DIR" "$BUILD_PRODUCTS_DIR/Donkey.app"
  mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$FRAMEWORKS_DIR"

  cp "$DONKEY_BIN" "$MACOS_DIR/$DEV_EXECUTABLE_NAME"
  if ! otool -l "$MACOS_DIR/$DEV_EXECUTABLE_NAME" | grep -q "@executable_path/../Frameworks"; then
    if ! command -v install_name_tool >/dev/null 2>&1; then
      echo "install_name_tool is required to package the Donkey debug app." >&2
      exit 1
    fi
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$MACOS_DIR/$DEV_EXECUTABLE_NAME"
  fi

  resource_bundle="$(find "$APP_DIR/.build" -path "*/debug/Donkey_Donkey.bundle" -type d | head -n 1 || true)"
  if [ -n "$resource_bundle" ]; then
    cp -R "$resource_bundle" "$RESOURCES_DIR/"
  else
    echo "Missing SwiftPM resource bundle for Donkey." >&2
    exit 1
  fi

  sparkle_framework="$(find "$APP_DIR/.build" -path "*/debug/Sparkle.framework" -type d | head -n 1 || true)"
  if [ -n "$sparkle_framework" ]; then
    cp -R "$sparkle_framework" "$FRAMEWORKS_DIR/"
  fi

  prepare_app_icon
  write_info_plist

  if command -v codesign >/dev/null 2>&1; then
    codesign_identity="$(resolve_codesign_identity)"
    if [ "$codesign_identity" = "-" ]; then
      echo "Signing debug app ad-hoc with a stable dev requirement."
      codesign \
        --force \
        --deep \
        --sign - \
        --identifier "$DEV_BUNDLE_IDENTIFIER" \
        --requirements "=designated => identifier \"$DEV_BUNDLE_IDENTIFIER\"" \
        "$DEV_APP_DIR" >/dev/null
    else
      echo "Signing debug app with $codesign_identity."
      codesign \
        --force \
        --deep \
        --sign "$codesign_identity" \
        --identifier "$DEV_BUNDLE_IDENTIFIER" \
        "$DEV_APP_DIR" >/dev/null
    fi
  fi

  if [ -x "$LSREGISTER" ]; then
    "$LSREGISTER" -f "$DEV_APP_DIR" >/dev/null 2>&1 || true
  fi
}

swift_build() {
  mkdir -p "$CACHE_CLANG_DIR" "$CACHE_SWIFTPM_DIR" "$CACHE_HOME_DIR"
  CLANG_MODULE_CACHE_PATH="$CACHE_CLANG_DIR" \
    SWIFTPM_CACHE_PATH="$CACHE_SWIFTPM_DIR" \
    HOME="$CACHE_HOME_DIR" \
    swift build --quiet
}

trap cleanup_on_exit EXIT
trap 'cleanup_on_signal 130' INT
trap 'cleanup_on_signal 143' TERM
trap 'cleanup_on_signal 129' HUP

ensure_site_server

if [ "${DONKEY_STOP_APPS_BEFORE_BUILD:-1}" = "1" ]; then
  echo "Stopping any running Donkey app..."
  stop_running_donkey_apps
fi

cd "$APP_DIR"

echo "Building Donkey..."
swift_build

if [ ! -x "$DONKEY_BIN" ]; then
  echo "Built Donkey executable was not found at $DONKEY_BIN." >&2
  exit 1
fi

echo "Creating debug app bundle..."
create_debug_app_bundle

echo "Prepared $DEV_APP_DIR"
if [ "$LAUNCH_APP" = "0" ]; then
  echo "Skipping Donkey launch because DONKEY_LAUNCH_APP=0."
  exit 0
fi

echo "Starting Donkey..."
print_dev_overlay_status
start_logger
open -W -n "$DEV_APP_DIR"
