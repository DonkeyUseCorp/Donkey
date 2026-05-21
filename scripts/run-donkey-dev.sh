#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/apps/Donkey"
LOG_SCRIPT="$ROOT_DIR/scripts/tail-donkey-logs.sh"
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

trap cleanup EXIT

echo "Stopping any running Donkey app..."
killall Donkey >/dev/null 2>&1 || true

cd "$APP_DIR"

echo "Building Donkey..."
swift build

echo "Starting Donkey..."
start_logger
swift run Donkey
