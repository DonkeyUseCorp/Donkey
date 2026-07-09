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

  # The on-device speech tool rides beside the engine binary: the engine puts
  # its own directory on PATH, so transcription works out of the box and the
  # tool updates in lockstep with the app.
  swift_arch="$arch"
  [ "$swift_arch" = "x64" ] && swift_arch="x86_64"
  stt="dist/cut-engine/cut-stt-$arch"
  echo "==> swiftc cut-stt ($arch)"
  swiftc -O -parse-as-library -target "$swift_arch-apple-macos26" \
    src/cut/server/native/cut-stt.swift -o "$stt"
done

# Dev runs the host-arch engine straight out of dist (the dev app symlinks it),
# so give the speech tool its bare name here for the beside-the-binary lookup.
if [ -f "dist/cut-engine/cut-stt-$host_arch" ]; then
  ln -sf "cut-stt-$host_arch" dist/cut-engine/cut-stt
fi
