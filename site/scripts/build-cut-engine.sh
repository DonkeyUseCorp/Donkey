#!/bin/bash
# Compile the Donkey Cut engine into single-file Mac binaries.
#
#   scripts/build-cut-engine.sh            # host arch (default)
#   ENGINE_ARCHES="arm64 x64" scripts/...  # explicit architectures
#
# Self-contained: installs site deps if they're missing, so dev and packaging can
# call it directly with no separate setup step. Output:
# dist/cut-engine/donkey-cut-engine-<arch>. The Donkey app bundles the binary and
# spawns it with DONKEY_CUT_ENGINE=1 (see plans/cut-engine.md).
set -euo pipefail
cd "$(dirname "$0")/.."

host_arch="$(uname -m)"
[ "$host_arch" = "x86_64" ] && host_arch="x64"
read -ra arches <<< "${ENGINE_ARCHES:-$host_arch}"

# bun ships as a site devDependency; make sure it and the engine's imports are present.
[ -d node_modules ] || npm ci

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
