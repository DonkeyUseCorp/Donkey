#!/bin/bash
# Compile the Donkey Cut engine into single-file Mac binaries.
#
#   scripts/build-cut-engine.sh            # arm64 (default)
#   ENGINE_ARCHES="arm64 x64" scripts/...  # both architectures
#
# Output: dist/cut-engine/donkey-cut-engine-<arch>. The Donkey app bundles
# the binary and spawns it with DONKEY_CUT_ENGINE=1 (see plans/cut-engine.md).
set -euo pipefail
cd "$(dirname "$0")/.."

read -ra arches <<< "${ENGINE_ARCHES:-arm64}"
mkdir -p dist/cut-engine

for arch in "${arches[@]}"; do
  out="dist/cut-engine/donkey-cut-engine-$arch"
  echo "==> bun build --compile ($arch)"
  npx bun build --compile --minify \
    --target="bun-darwin-$arch" \
    src/cut/engine/main.ts \
    --outfile "$out"
  echo "==> built $out ($(du -h "$out" | cut -f1))"
done
