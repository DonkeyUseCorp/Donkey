#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/apps/Donkey"
LOG_SCRIPT="$ROOT_DIR/scripts/tail-donkey-logs.sh"
DONKEY_BIN="$APP_DIR/.build/debug/Donkey"
DEV_RUNTIME_MANIFEST_SCRIPT="$ROOT_DIR/scripts/create-dev-runtime-manifests.py"
DEV_RUNTIME_SETUP_SCRIPT="$ROOT_DIR/scripts/setup-dev-local-runtimes.py"
PACKAGE_SCRIPT="$ROOT_DIR/scripts/package-donkey-app.sh"
DEV_RUNTIME_PACKAGE_DIR="${DONKEY_DEV_RUNTIME_PACKAGE_DIR:-$ROOT_DIR/dist/LocalRuntimePackages}"
DEV_RUNTIME_ENV_FILE="${DONKEY_DEV_RUNTIME_ENV_FILE:-$ROOT_DIR/dist/donkey-dev-runtime-manifests.env}"
LOCAL_LLM_MODEL_CONFIG="${DONKEY_LOCAL_LLM_MODEL_CONFIG:-$ROOT_DIR/config/local-llm-models.json}"
LOG_PID=""

cleanup() {
  if [ -n "$LOG_PID" ] && kill -0 "$LOG_PID" >/dev/null 2>&1; then
    kill "$LOG_PID" >/dev/null 2>&1 || true
    wait "$LOG_PID" >/dev/null 2>&1 || true
  fi
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

runtime_manifest_env_is_configured() {
  [ -n "${DONKEY_RUNTIME_PACKAGE_MANIFEST_URLS:-}" ] \
    || [ -n "${DONKEY_PARAKEET_RUNTIME_MANIFEST_URL:-}" ] \
    || [ -n "${DONKEY_YOLO_RUNTIME_MANIFEST_URL:-}" ] \
    || [ -n "${DONKEY_UI_UNDERSTANDER_RUNTIME_MANIFEST_URL:-}" ] \
    || [ -n "${DONKEY_LOCAL_LLM_RUNTIME_MANIFEST_URL:-}" ]
}

dev_runtime_packages_need_refresh() {
  if [ "${DONKEY_DEV_RUNTIME_PACKAGE_REFRESH:-0}" = "1" ]; then
    return 0
  fi
  if [ ! -d "$DEV_RUNTIME_PACKAGE_DIR" ]; then
    return 0
  fi
  python3 - "$DEV_RUNTIME_PACKAGE_DIR" "$LOCAL_LLM_MODEL_CONFIG" <<'PY'
import json
import os
import sys
from pathlib import Path

package_dir = Path(sys.argv[1])
config_path = Path(sys.argv[2])
expected_runtimes = {"local-llm", "parakeet-transcriber", "ui-understander", "yolo-segmenter"}
for runtime_id in expected_runtimes:
    if not (package_dir / runtime_id / "manifest.json").exists():
        raise SystemExit(0)
manifest_path = package_dir / "local-llm" / "manifest.json"
if not manifest_path.exists():
    raise SystemExit(0)
try:
    manifest = json.loads(manifest_path.read_text())
except Exception:
    raise SystemExit(0)
metadata = manifest.get("metadata") if isinstance(manifest.get("metadata"), dict) else {}
files = manifest.get("files") if isinstance(manifest.get("files"), list) else []
requirements_path = package_dir / "local-llm" / "requirements.txt"
try:
    config = json.loads(config_path.read_text())
except Exception:
    raise SystemExit(0)
model = config.get("defaultModel")
if not isinstance(model, dict):
    raise SystemExit(0)
expected_model_id = os.environ.get("DONKEY_LOCAL_LLM_MODEL_ID") or str(model.get("modelID") or "")
expected_model_url = os.environ.get("DONKEY_LOCAL_LLM_MODEL_URL") or str(model.get("downloadURL") or "")
expected_model_sha256 = (
    os.environ.get("DONKEY_LOCAL_LLM_MODEL_SHA256")
    or str(model.get("sha256") or model.get("expectedSHA256") or "")
)
expected_model_filename = os.environ.get("DONKEY_LOCAL_LLM_MODEL_FILENAME") or str(model.get("filename") or "")
expected_requirements = config.get("runtimeRequirements") if isinstance(config.get("runtimeRequirements"), list) else []
expected_requirements_text = "\n".join(str(item) for item in expected_requirements if str(item).strip()).strip()
if str(manifest.get("modelID") or "") != expected_model_id:
    raise SystemExit(0)
if str(metadata.get("modelWeights.downloadURL") or "") != expected_model_url:
    raise SystemExit(0)
if str(metadata.get("modelWeights.sha256") or "") != expected_model_sha256:
    raise SystemExit(0)
if str(metadata.get("modelWeights.filename") or "") != expected_model_filename:
    raise SystemExit(0)
if not str(metadata.get("modelWeights.downloadURL") or "").strip():
    raise SystemExit(0)
if not str(metadata.get("modelWeights.sha256") or "").strip():
    raise SystemExit(0)
if not requirements_path.exists():
    raise SystemExit(0)
actual_requirements_text = requirements_path.read_text().strip()
if actual_requirements_text != expected_requirements_text:
    raise SystemExit(0)
if not files:
    raise SystemExit(0)
raise SystemExit(1)
PY
}

refresh_dev_runtime_packages_if_needed() {
  if runtime_manifest_env_is_configured; then
    return
  fi
  if [ "${DONKEY_DEV_RUNTIME_AUTO_PACKAGE:-1}" = "0" ]; then
    return
  fi
  if ! dev_runtime_packages_need_refresh; then
    return
  fi

  echo "Refreshing local runtime packages for dev setup..."
  "$PACKAGE_SCRIPT"
}

load_dev_runtime_manifests() {
  if runtime_manifest_env_is_configured; then
    echo "Using runtime manifest URLs from environment."
    return
  fi

  if [ "${DONKEY_DEV_RUNTIME_MANIFESTS:-1}" = "0" ]; then
    echo "Skipping dev runtime manifest setup because DONKEY_DEV_RUNTIME_MANIFESTS=0."
    return
  fi

  if [ -d "$DEV_RUNTIME_PACKAGE_DIR" ]; then
    echo "Refreshing local runtime manifest env from $DEV_RUNTIME_PACKAGE_DIR..."
    DONKEY_DEV_RUNTIME_PACKAGE_DIR="$DEV_RUNTIME_PACKAGE_DIR" \
      DONKEY_DEV_RUNTIME_ENV_FILE="$DEV_RUNTIME_ENV_FILE" \
      python3 "$DEV_RUNTIME_MANIFEST_SCRIPT" || true
  fi

  if [ -f "$DEV_RUNTIME_ENV_FILE" ]; then
    echo "Loading local runtime manifest env from $DEV_RUNTIME_ENV_FILE..."
    # shellcheck source=/dev/null
    source "$DEV_RUNTIME_ENV_FILE"
    return
  fi

  echo "No local runtime manifest env found. Check package output above, or set DONKEY_RUNTIME_PACKAGE_MANIFEST_URLS."
}

setup_missing_local_runtimes() {
  if [ "${DONKEY_DEV_RUNTIME_SETUP:-1}" = "0" ]; then
    echo "Skipping local runtime setup because DONKEY_DEV_RUNTIME_SETUP=0."
    return
  fi

  if ! runtime_manifest_env_is_configured; then
    echo "Skipping local runtime setup because no runtime manifest URLs are configured."
    return
  fi

  echo "Setting up missing local runtimes..."
  if ! python3 "$DEV_RUNTIME_SETUP_SCRIPT"; then
    echo "Warning: dev local runtime setup failed; continuing to launch Donkey." >&2
  fi
}

trap cleanup EXIT

echo "Stopping any running Donkey app..."
killall Donkey >/dev/null 2>&1 || true

refresh_dev_runtime_packages_if_needed
load_dev_runtime_manifests

cd "$APP_DIR"

echo "Building Donkey..."
swift build --quiet

if [ ! -x "$DONKEY_BIN" ]; then
  echo "Built Donkey executable was not found at $DONKEY_BIN." >&2
  exit 1
fi

setup_missing_local_runtimes

echo "Starting Donkey..."
start_logger
"$DONKEY_BIN"
