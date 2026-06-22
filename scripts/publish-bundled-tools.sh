#!/usr/bin/env bash
#
# Builds the prebuilt CLI tools bundle (ffmpeg, yt-dlp, ...) from source and publishes it as a GitHub
# release asset, then rewrites bundled-tools.json (version, url, sha256) so the shipped app and the dev
# script fetch the new bundle. This is the ONE place the heavy source build runs — end users and dev
# machines only ever download the result.
#
# Run on an arm64 macOS build machine with Homebrew + Xcode and an authenticated `gh`. Usage:
#   scripts/publish-bundled-tools.sh [version]   # version defaults to today's date (YYYY.MM.DD)
#
# After it finishes, commit the updated bundled-tools.json so the app ships pointing at the new asset.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
VENDOR_DIR="$ROOT_DIR/vendor/donkey-tools"
MANIFEST="$ROOT_DIR/apps/Donkey/Sources/DonkeyRuntime/Resources/bundled-tools.json"

REPO="${DONKEY_TOOLS_REPO:-DonkeyUseCorp/Donkey}"
ARCH="arm64"
VERSION="${1:-$(date +%Y.%m.%d)}"
TAG="bundled-tools-$VERSION"
ASSET="donkey-tools-$VERSION-$ARCH.tar.gz"
URL="https://github.com/$REPO/releases/download/$TAG/$ASSET"
OUT="/tmp/$ASSET"

MANDATORY_TOOLS=(ffmpeg ffprobe yt-dlp lit pdf-fill)

echo "==> Building tools from source (idempotent; skips already-built)"
"$SCRIPT_DIR/fetch-bundled-tools.sh"

for t in "${MANDATORY_TOOLS[@]}"; do
  [ -x "$VENDOR_DIR/$t" ] || { echo "FATAL: $t missing from $VENDOR_DIR after build" >&2; exit 1; }
done

# NOTE: for public distribution the binaries should be Developer ID-signed and the tarball notarized here,
# or Gatekeeper will block first launch of the downloaded tools. Left as a deliberate follow-up; the
# checksum in the manifest already guarantees integrity of the download.

echo "==> Packaging $ASSET (bundle contents at archive root)"
rm -f "$OUT"
tar -czf "$OUT" -C "$VENDOR_DIR" .
SHA="$(shasum -a 256 "$OUT" | awk '{print $1}')"
echo "    size=$(du -h "$OUT" | awk '{print $1}')  sha256=$SHA"

echo "==> Updating $MANIFEST"
python3 - "$MANIFEST" "$VERSION" "$ARCH" "$URL" "$SHA" <<'PY'
import json, sys
path, version, arch, url, sha = sys.argv[1:6]
m = json.load(open(path))
m["version"] = version
m["arch"] = arch
m["url"] = url
m["sha256"] = sha
with open(path, "w") as f:
    json.dump(m, f, indent=2)
    f.write("\n")
PY

echo "==> Publishing to GitHub release $TAG ($REPO)"
if ! gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  gh release create "$TAG" --repo "$REPO" --title "$TAG" \
    --notes "Prebuilt Donkey CLI tools ($ARCH) — $VERSION."
fi
gh release upload "$TAG" "$OUT" --repo "$REPO" --clobber

echo
echo "Published $ASSET → $URL"
echo "Now commit the updated $MANIFEST so the app ships pointing at this bundle."
