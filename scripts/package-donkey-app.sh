#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/dist/Donkey.app"
DMG_PATH="$ROOT_DIR/dist/Donkey.dmg"
DMG_ROOT="$ROOT_DIR/dist/DonkeyInstaller"
RUNTIME_PACKAGE_DIR="$ROOT_DIR/dist/LocalRuntimePackages"
RUNTIME_PACKAGE_VERSION="${DONKEY_RUNTIME_PACKAGE_VERSION:-0.3.0-runner}"
RUNTIME_PACKAGE_BASE_URL="${DONKEY_RUNTIME_PACKAGE_BASE_URL:-}"
RUNTIME_PACKAGE_MANIFEST_URLS="${DONKEY_RUNTIME_PACKAGE_MANIFEST_URLS:-}"
APP_VERSION="${DONKEY_APP_VERSION:-0.1.0}"
APP_BUILD="${DONKEY_APP_BUILD:-1}"
SPARKLE_FEED_URL="${DONKEY_SPARKLE_FEED_URL:-}"
SPARKLE_PUBLIC_ED_KEY="${DONKEY_SPARKLE_PUBLIC_ED_KEY:-}"
RUNTIME_MANIFEST_PUBLIC_KEYS="${DONKEY_RUNTIME_MANIFEST_PUBLIC_KEYS:-}"
RUNTIME_REQUIRE_CRYPTO_SIGNATURES="${DONKEY_RUNTIME_REQUIRE_CRYPTO_SIGNATURES:-0}"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
FRAMEWORKS_DIR="$CONTENTS_DIR/Frameworks"
BUILD_DIR="$ROOT_DIR/apps/Donkey"
EXECUTABLE="$BUILD_DIR/.build/release/Donkey"
UI_UNDERSTANDER_EXECUTABLE="$BUILD_DIR/.build/release/DonkeyUIUnderstandingSidecar"
CACHE_DIR="$BUILD_DIR/.build/package-cache"
RUNTIME_RUNNER_SOURCE="$ROOT_DIR/scripts/local-runtime-runners/donkey_runtime_runner.py"

mkdir -p "$CACHE_DIR/clang" "$CACHE_DIR/swiftpm" "$CACHE_DIR/home"
export CLANG_MODULE_CACHE_PATH="$CACHE_DIR/clang"
export SWIFTPM_CACHE_PATH="$CACHE_DIR/swiftpm"
export HOME="$CACHE_DIR/home"

manifest_download_url_entry() {
  local runtime_id="$1"
  local relative_path="$2"
  if [ -n "$RUNTIME_PACKAGE_BASE_URL" ]; then
    printf ',\n      "downloadURL" : "%s/%s/%s"' "${RUNTIME_PACKAGE_BASE_URL%/}" "$runtime_id" "$relative_path"
  fi
}

cd "$BUILD_DIR"
echo "Compiling Donkey for Mac ..."
swift build -c release --product Donkey
swift build -c release --product DonkeyUIUnderstandingSidecar

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

make_runtime_package() {
  local runtime_id="$1"
  local executable_name="$2"
  local model_id="$3"
  local role="$4"
  local model_url="${5:-}"
  local model_sha256="${6:-}"
  local model_filename="${7:-model.bin}"
  local requirements="${8:-}"
  local package_dir="$RUNTIME_PACKAGE_DIR/$runtime_id"
  local bin_dir="$package_dir/bin"
  local lib_dir="$package_dir/lib"
  local executable_path="$bin_dir/$executable_name"
  local runner_path="$lib_dir/donkey_runtime_runner.py"
  local requirements_path="$package_dir/requirements.txt"

  mkdir -p "$bin_dir" "$lib_dir"
  cp "$RUNTIME_RUNNER_SOURCE" "$runner_path"
  chmod 755 "$runner_path"
  cat > "$executable_path" <<EOF_RUNTIME
#!/usr/bin/env sh
SCRIPT_DIR="\$(CDPATH= cd -- "\$(dirname -- "\$0")" && pwd)"
PYTHON="\${DONKEY_RUNTIME_PYTHON:-python3}"
PACKAGE_DIR="\$(CDPATH= cd -- "\$SCRIPT_DIR/.." && pwd)"
export DONKEY_RUNTIME_ID="$runtime_id"
export DONKEY_RUNTIME_VERSION="$RUNTIME_PACKAGE_VERSION"
export DONKEY_MODEL_ID="$model_id"
export DONKEY_RUNTIME_ROLE="$role"
export DONKEY_MODEL_URL="$model_url"
export DONKEY_MODEL_SHA256="$model_sha256"
export DONKEY_MODEL_FILENAME="$model_filename"
export DONKEY_RUNTIME_PACKAGE_DIR="\$PACKAGE_DIR"
export DONKEY_RUNTIME_STATE_DIR="\${DONKEY_RUNTIME_STATE_DIR:-\$HOME/Library/Application Support/Donkey/LocalModelRuntimes/RuntimePython/$runtime_id}"
if ! command -v "\$PYTHON" >/dev/null 2>&1; then
  printf '{"status":"error","runtimeID":"%s","modelID":"%s","metadata":{"reason":"pythonRuntimeUnavailable","dependency":"python3"}}' "$runtime_id" "$model_id"
  exit 0
fi
exec "\$PYTHON" "\$SCRIPT_DIR/../lib/donkey_runtime_runner.py"
EOF_RUNTIME
  chmod 755 "$executable_path"
  if [ -n "$requirements" ]; then
    printf '%s\n' "$requirements" > "$requirements_path"
  fi

  local executable_sha
  local runner_sha
  local requirements_sha=""
  local requirements_manifest_entry=""
  executable_sha="$(shasum -a 256 "$executable_path" | awk '{print $1}')"
  runner_sha="$(shasum -a 256 "$runner_path" | awk '{print $1}')"
  local executable_download_url_entry
  local runner_download_url_entry
  executable_download_url_entry="$(manifest_download_url_entry "$runtime_id" "bin/$executable_name")"
  runner_download_url_entry="$(manifest_download_url_entry "$runtime_id" "lib/donkey_runtime_runner.py")"
  if [ -f "$requirements_path" ]; then
    requirements_sha="$(shasum -a 256 "$requirements_path" | awk '{print $1}')"
    local requirements_download_url_entry
    requirements_download_url_entry="$(manifest_download_url_entry "$runtime_id" "requirements.txt")"
    requirements_manifest_entry=",
    {
      \"relativePath\" : \"requirements.txt\"$requirements_download_url_entry,
      \"sha256\" : \"$requirements_sha\",
      \"isExecutable\" : false
    }"
  fi
  cat > "$package_dir/manifest.json" <<EOF_MANIFEST
{
  "runtimeID" : "$runtime_id",
  "runtimeVersion" : "$RUNTIME_PACKAGE_VERSION",
  "modelID" : "$model_id",
  "platform" : "macos",
  "architecture" : "$(uname -m | sed 's/aarch64/arm64/;s/x86_64/x86_64/')",
  "sidecarProtocolVersion" : "v1",
  "minimumDonkeyVersion" : "0.1.0",
  "executableRelativePath" : "bin/$executable_name",
  "files" : [
    {
      "relativePath" : "bin/$executable_name"$executable_download_url_entry,
      "sha256" : "$executable_sha",
      "isExecutable" : true
    },
    {
      "relativePath" : "lib/donkey_runtime_runner.py"$runner_download_url_entry,
      "sha256" : "$runner_sha",
      "isExecutable" : true
    }$requirements_manifest_entry
  ],
  "signature" : "donkey-runner-package",
  "signingKeyID" : "donkey-runner",
  "metadata" : {
    "runtime.package" : "donkey-runner-package",
    "modelWeightsBundled" : "false",
    "modelWeights.downloadURL" : "$model_url",
    "modelWeights.sha256" : "$model_sha256",
    "modelWeights.filename" : "$model_filename",
    "sidecar.role" : "$role"
  }
}
EOF_MANIFEST
}

make_binary_runtime_package() {
  local runtime_id="$1"
  local executable_name="$2"
  local source_executable="$3"
  local model_id="$4"
  local role="$5"
  local package_dir="$RUNTIME_PACKAGE_DIR/$runtime_id"
  local bin_dir="$package_dir/bin"
  local executable_path="$bin_dir/$executable_name"

  mkdir -p "$bin_dir"
  cp "$source_executable" "$executable_path"
  chmod 755 "$executable_path"

  local executable_sha
  executable_sha="$(shasum -a 256 "$executable_path" | awk '{print $1}')"
  local executable_download_url_entry
  executable_download_url_entry="$(manifest_download_url_entry "$runtime_id" "bin/$executable_name")"
  cat > "$package_dir/manifest.json" <<EOF_MANIFEST
{
  "runtimeID" : "$runtime_id",
  "runtimeVersion" : "$RUNTIME_PACKAGE_VERSION",
  "modelID" : "$model_id",
  "platform" : "macos",
  "architecture" : "$(uname -m | sed 's/aarch64/arm64/;s/x86_64/x86_64/')",
  "sidecarProtocolVersion" : "v1",
  "minimumDonkeyVersion" : "0.1.0",
  "executableRelativePath" : "bin/$executable_name",
  "files" : [
    {
      "relativePath" : "bin/$executable_name"$executable_download_url_entry,
      "sha256" : "$executable_sha",
      "isExecutable" : true
    }
  ],
  "signature" : "donkey-runner-package",
  "signingKeyID" : "donkey-runner",
  "metadata" : {
    "runtime.package" : "donkey-binary-runtime-package",
    "modelWeightsBundled" : "false",
    "modelWeights.status" : "notRequired",
    "modelWeights.provider" : "system",
    "sidecar.role" : "$role"
  }
}
EOF_MANIFEST
}

rm -rf "$RUNTIME_PACKAGE_DIR"
mkdir -p "$RUNTIME_PACKAGE_DIR"
make_runtime_package "parakeet-transcriber" "donkey-parakeet-transcriber" "nvidia/parakeet-tdt-0.6b-v3" "voiceTranscription" "${DONKEY_PARAKEET_MODEL_URL:-}" "${DONKEY_PARAKEET_MODEL_SHA256:-}" "${DONKEY_PARAKEET_MODEL_FILENAME:-parakeet-model.bin}" $'huggingface_hub>=0.25,<1'
make_runtime_package "yolo-segmenter" "donkey-yolo-segmenter" "ultralytics/yolo26n-seg" "screenshotSegmentation" "${DONKEY_YOLO_MODEL_URL:-}" "${DONKEY_YOLO_MODEL_SHA256:-}" "${DONKEY_YOLO_MODEL_FILENAME:-yolo26n-seg.pt}" $'ultralytics>=8.3,<9\nopencv-python-headless>=4.10,<5'
make_binary_runtime_package "ui-understander" "donkey-ui-understander" "$UI_UNDERSTANDER_EXECUTABLE" "apple-vision-text-recognition" "uiUnderstanding"
make_runtime_package "local-llm" "donkey-local-llm" "${DONKEY_LOCAL_LLM_MODEL_ID:-qwen3:8b}" "localLLM" "" "" "${DONKEY_LOCAL_LLM_MODEL_FILENAME:-ollama-qwen3-8b}"

RESOURCE_BUNDLE="$(find "$BUILD_DIR/.build" -path "*/release/Donkey_Donkey.bundle" -type d | head -n 1 || true)"
if [ -n "$RESOURCE_BUNDLE" ]; then
  cp -R "$RESOURCE_BUNDLE" "$RESOURCES_DIR/"
elif [ -d "$BUILD_DIR/.build/release/Donkey_Donkey.resources" ]; then
  cp -R "$BUILD_DIR/.build/release/Donkey_Donkey.resources/." "$RESOURCES_DIR/"
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

RUNTIME_SIGNATURE_PLIST_KEYS=""
if [ -n "$RUNTIME_MANIFEST_PUBLIC_KEYS" ]; then
  RUNTIME_SIGNATURE_PLIST_KEYS="  <key>DonkeyRuntimeRequiresCryptographicManifestSignatures</key>
  <$( [ "$RUNTIME_REQUIRE_CRYPTO_SIGNATURES" = "1" ] && printf true || printf false )/>
  <key>DonkeyRuntimeManifestPublicKeys</key>
  <dict>"
  IFS=',' read -r -a runtime_key_pairs <<< "$RUNTIME_MANIFEST_PUBLIC_KEYS"
  for pair in "${runtime_key_pairs[@]}"; do
    key_id="${pair%%=*}"
    public_key="${pair#*=}"
    if [ -n "$key_id" ] && [ -n "$public_key" ] && [ "$key_id" != "$public_key" ]; then
      RUNTIME_SIGNATURE_PLIST_KEYS="$RUNTIME_SIGNATURE_PLIST_KEYS
    <key>$key_id</key>
    <string>$public_key</string>"
    fi
  done
  RUNTIME_SIGNATURE_PLIST_KEYS="$RUNTIME_SIGNATURE_PLIST_KEYS
  </dict>"
fi

RUNTIME_PACKAGE_MANIFEST_PLIST_KEYS=""
append_runtime_package_manifest_url() {
  local runtime_id="$1"
  local manifest_url="$2"
  if [ -z "$runtime_id" ] || [ -z "$manifest_url" ]; then
    return
  fi
  RUNTIME_PACKAGE_MANIFEST_PLIST_KEYS="$RUNTIME_PACKAGE_MANIFEST_PLIST_KEYS
    <key>$runtime_id</key>
    <string>$manifest_url</string>"
}

if [ -n "$RUNTIME_PACKAGE_MANIFEST_URLS" ]; then
  IFS=',' read -r -a manifest_url_pairs <<< "$RUNTIME_PACKAGE_MANIFEST_URLS"
  for pair in "${manifest_url_pairs[@]}"; do
    runtime_id="${pair%%=*}"
    manifest_url="${pair#*=}"
    if [ "$runtime_id" != "$manifest_url" ]; then
      append_runtime_package_manifest_url "$runtime_id" "$manifest_url"
    fi
  done
fi
append_runtime_package_manifest_url "parakeet-transcriber" "${DONKEY_PARAKEET_RUNTIME_MANIFEST_URL:-}"
append_runtime_package_manifest_url "yolo-segmenter" "${DONKEY_YOLO_RUNTIME_MANIFEST_URL:-}"
append_runtime_package_manifest_url "ui-understander" "${DONKEY_UI_UNDERSTANDER_RUNTIME_MANIFEST_URL:-}"
append_runtime_package_manifest_url "local-llm" "${DONKEY_LOCAL_LLM_RUNTIME_MANIFEST_URL:-}"

if [ -n "$RUNTIME_PACKAGE_MANIFEST_PLIST_KEYS" ]; then
  RUNTIME_PACKAGE_MANIFEST_PLIST_KEYS="  <key>DonkeyRuntimePackageManifestURLs</key>
  <dict>$RUNTIME_PACKAGE_MANIFEST_PLIST_KEYS
  </dict>"
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
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$APP_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$APP_BUILD</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSMicrophoneUsageDescription</key>
  <string>Donkey uses the microphone for local voice commands.</string>
  <key>NSScreenCaptureUsageDescription</key>
  <string>Donkey captures bounded screenshots so local runtimes can understand app UI.</string>
  <key>NSAppleEventsUsageDescription</key>
  <string>Donkey uses local app automation only for user-requested actions.</string>
$SPARKLE_PLIST_KEYS
$RUNTIME_PACKAGE_MANIFEST_PLIST_KEYS
$RUNTIME_SIGNATURE_PLIST_KEYS
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
