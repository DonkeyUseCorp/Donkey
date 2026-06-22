#!/usr/bin/env bash
#
# Code-signs every Mach-O in a bundled-tools directory (the binaries + their @loader_path dylibs).
# REQUIRED, not cosmetic: dylibbundler rewrites install names, which invalidates any existing signature,
# and the Apple Silicon kernel kills an unsigned/invalidly-signed Mach-O on exec. So the vendored tools
# must be (re)signed or they won't run on the user's Mac.
#
# Identity comes from DONKEY_TOOLS_SIGN_IDENTITY:
#   "-" (default)         ad-hoc — runs locally and on any arm64 Mac for non-quarantined files (dev).
#   "Developer ID ..."    real identity + hardened runtime + secure timestamp (production); pair with
#                         notarization (see publish-bundled-tools.sh) for distribution.
#
# Usage: scripts/sign-bundled-tools.sh [vendor-dir]   (default: vendor/donkey-tools)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
VENDOR_DIR="${1:-$ROOT_DIR/vendor/donkey-tools}"
IDENTITY="${DONKEY_TOOLS_SIGN_IDENTITY:--}"

if [ ! -d "$VENDOR_DIR" ]; then
  echo "sign-bundled-tools: $VENDOR_DIR does not exist" >&2
  exit 1
fi

sign_opts=(--force --sign "$IDENTITY")
real_identity=false
if [ "$IDENTITY" != "-" ]; then
  # Hardened runtime + secure timestamp are required for notarization to accept the binaries.
  sign_opts+=(--options runtime --timestamp)
  real_identity=true
fi

is_macho() { file -b "$1" 2>/dev/null | grep -q "Mach-O"; }

# A signing failure under a real identity must abort (an unsigned prod binary is a broken release); under
# ad-hoc it's tolerated so a non-Mach-O file (e.g. the exiftool Perl script) is simply skipped.
sign_one() {
  local f="$1"
  is_macho "$f" || return 0
  if codesign "${sign_opts[@]}" "$f" >/dev/null 2>&1; then
    return 0
  fi
  if $real_identity; then
    echo "FATAL: failed to sign $f with '$IDENTITY'" >&2
    exit 1
  fi
}

# Inside-out: dylibs (the dependencies) before the executables that load them.
while IFS= read -r -d '' f; do sign_one "$f"; done \
  < <(find "$VENDOR_DIR" -type f -name "*.dylib" -print0)
while IFS= read -r -d '' f; do
  case "$f" in *.dylib) continue ;; esac
  sign_one "$f"
done < <(find "$VENDOR_DIR" -maxdepth 1 -type f -perm -u+x -print0)

if $real_identity; then
  echo "Signed bundled tools in $VENDOR_DIR with '$IDENTITY' (hardened runtime)."
else
  echo "Ad-hoc signed bundled tools in $VENDOR_DIR."
fi
