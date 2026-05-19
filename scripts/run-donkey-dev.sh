#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/apps/Donkey"

echo "Stopping any running Donkey app..."
killall Donkey >/dev/null 2>&1 || true

cd "$APP_DIR"

echo "Building Donkey..."
swift build

echo "Starting Donkey..."
exec swift run Donkey
