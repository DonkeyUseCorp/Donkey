#!/usr/bin/env bash
#
# Guarantees vendor/donkey-tools/ holds the command-line tools Donkey's capability
# skills run by bare name (yt-dlp, ffmpeg, ...). The dev run script and the offline
# packaging override both call this, so the tools are present without a manual step.
#
# Strategy: prefer the published prebuilt bundle named in bundled-tools.json (a fast
# download, the same artifact the shipped app installs on first run). If nothing is
# published yet, or the download/checksum fails, fall back to building from source via
# fetch-bundled-tools.sh. Either way, fail loudly if a mandatory tool is still missing
# rather than letting a build run without the media/pdf capabilities.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
VENDOR_DIR="${DONKEY_TOOLS_DIR:-$ROOT_DIR/vendor/donkey-tools}"
MANIFEST="$ROOT_DIR/apps/Donkey/Sources/DonkeyRuntime/Resources/bundled-tools.json"

# Tools without which a build is not shippable: ffmpeg/ffprobe (media), yt-dlp (the
# YouTube/download path), lit + pdf-fill (the pdf skill), epub-pack (the book skill),
# reframe (the shorts skill's active-speaker auto-reframe).
# Keep in sync with fetch-bundled-tools.sh and BundledTools.swift.
MANDATORY_TOOLS=(ffmpeg ffprobe yt-dlp lit pdf-fill epub-pack reframe)
OPTIONAL_TOOLS=(qpdf exiftool)

missing_of() {
  local t out=()
  for t in "$@"; do
    [ -x "$VENDOR_DIR/$t" ] || out+=("$t")
  done
  printf '%s\n' "${out[@]:-}"
}

# `lit` loads pdfium at runtime via PDFIUM_LIB_PATH; without libpdfium.dylib beside it, every PDF parse
# fails. The dylib is not an executable, so it can't live in MANDATORY_TOOLS — check it as lit's companion.
pdfium_missing() {
  [ -x "$VENDOR_DIR/lit" ] && [ ! -f "$VENDOR_DIR/libpdfium.dylib" ]
}

# True only when a bundled-tool SOURCE file has local (uncommitted) changes — the dev is iterating, so the
# staged binary is stale and fetch-bundled-tools.sh should rebuild just that tool (its own per-tool `-nt`
# guard decides which). Detected with git, NOT file mtimes: a fresh clone / CI checkout has clone-order
# mtimes that made the old `-nt` check fire spuriously and recompile a perfectly good prebuilt bundle.
# `tools/` covers every compiled tool generically (no per-tool path list to keep in sync — that lives once,
# in fetch-bundled-tools.sh); ReframePlanner.swift is reframe's one source outside `tools/`. Outside a git
# tree (a source tarball) nothing is being edited, so treat as unchanged.
any_source_modified() {
  git -C "$ROOT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
  ! git -C "$ROOT_DIR" diff --quiet HEAD -- \
      tools/ \
      apps/Donkey/Sources/DonkeyRuntime/ReframePlanner.swift
}


manifest_value() {
  [ -f "$MANIFEST" ] || return 1
  python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2],''))" "$MANIFEST" "$1" 2>/dev/null
}

# Download + verify + extract the published prebuilt bundle into VENDOR_DIR. Returns
# non-zero (so the caller falls back to a source build) when nothing is published yet.
download_prebuilt() {
  local url sha
  url="$(manifest_value url || true)"
  sha="$(manifest_value sha256 || true)"
  if [ -z "$sha" ] || [ -z "$url" ]; then
    echo "No published tools bundle yet (bundled-tools.json has no sha256)."
    return 1
  fi
  local tmp stage got root
  tmp="$(mktemp)"; stage="$(mktemp -d)"
  echo "Downloading prebuilt tools: $url"
  if ! curl -fsSL -o "$tmp" "$url"; then
    echo "Download failed." >&2; rm -rf "$tmp" "$stage"; return 1
  fi
  got="$(shasum -a 256 "$tmp" | awk '{print $1}')"
  if [ "$got" != "$sha" ]; then
    echo "Checksum mismatch (expected $sha, got $got)." >&2; rm -rf "$tmp" "$stage"; return 1
  fi
  if ! tar -xzf "$tmp" -C "$stage"; then
    echo "Extract failed." >&2; rm -rf "$tmp" "$stage"; return 1
  fi
  # The tarball may be flat (ffmpeg at the root) or wrapped in a top-level dir.
  root="$stage"
  [ -x "$stage/ffmpeg" ] || root="$(find "$stage" -maxdepth 2 -name ffmpeg -type f -exec dirname {} \; | head -1)"
  if [ -z "$root" ] || [ ! -x "$root/ffmpeg" ]; then
    echo "Archive did not contain ffmpeg." >&2; rm -rf "$tmp" "$stage"; return 1
  fi
  rm -rf "$VENDOR_DIR"; mkdir -p "$(dirname "$VENDOR_DIR")"; mv "$root" "$VENDOR_DIR"
  rm -rf "$tmp" "$stage"
  echo "Installed prebuilt tools into $VENDOR_DIR."
}

# A custom DONKEY_TOOLS_DIR is a caller-supplied prebuilt set: validate what's present and NEVER build into
# it (nor rebuild for source-change reasons — the prebuilt binaries are authoritative). A complete set is
# done; only a genuinely missing tool fails, with the real list rather than an empty one.
if [ -n "${DONKEY_TOOLS_DIR:-}" ]; then
  missing="$(missing_of "${MANDATORY_TOOLS[@]}" | grep -v '^$' | tr '\n' ' ')"
  pdfium_missing && missing="$missing libpdfium.dylib"
  missing="$(echo "$missing" | xargs)"
  if [ -n "$missing" ]; then
    echo "ERROR: DONKEY_TOOLS_DIR=$VENDOR_DIR is missing required tools: $missing" >&2
    exit 1
  fi
  echo "Bundled tools present in $VENDOR_DIR (DONKEY_TOOLS_DIR)"
  exit 0
fi

mandatory_missing=$(missing_of "${MANDATORY_TOOLS[@]}" | grep -c .)
optional_missing=$(missing_of "${OPTIONAL_TOOLS[@]}" | grep -c .)
if [ "$mandatory_missing" -eq 0 ] && [ "$optional_missing" -eq 0 ] && ! pdfium_missing && ! any_source_modified; then
  echo "Bundled tools present in $VENDOR_DIR"
  exit 0
fi

if any_source_modified; then
  echo "Source changes detected in tools/ — compiling custom tools..."
  "$SCRIPT_DIR/fetch-bundled-tools.sh" || true
elif pdfium_missing; then
  echo "Staged libpdfium.dylib is missing — attempting to restore from prebuilt..."
  if ! download_prebuilt; then
    echo "Could not restore prebuilt tools. Compiling from source..."
    "$SCRIPT_DIR/fetch-bundled-tools.sh" || true
  fi
elif ! download_prebuilt; then
  echo "Building tools from source (one-time; ffmpeg builds from source and can take several minutes)..."
  "$SCRIPT_DIR/fetch-bundled-tools.sh" || true
fi


# A published prebuilt bundle can predate a newly added mandatory tool (e.g. a first-party CLI
# added to the scripts before the next republish). Rather than hard-fail, build just the missing
# ones from source — fetch-bundled-tools.sh skips anything already present in VENDOR_DIR.
still_mandatory=$(missing_of "${MANDATORY_TOOLS[@]}" | grep -v '^$' || true)
if [ -n "$still_mandatory" ]; then
  echo "Prebuilt bundle missing: $(echo "$still_mandatory" | tr '\n' ' ')— building those from source..."
  "$SCRIPT_DIR/fetch-bundled-tools.sh" || true
  still_mandatory=$(missing_of "${MANDATORY_TOOLS[@]}" | grep -v '^$' || true)
fi
if [ -n "$still_mandatory" ]; then
  echo "ERROR: bundled tools still missing after install: $(echo "$still_mandatory" | tr '\n' ' ')" >&2
  echo "       Source build needs Homebrew + network; fix that and re-run." >&2
  exit 1
fi
if pdfium_missing; then
  echo "Staged libpdfium.dylib is missing — compiling/fetching it from source..."
  "$SCRIPT_DIR/fetch-bundled-tools.sh" || true
fi
if pdfium_missing; then
  echo "ERROR: lit is present but libpdfium.dylib is still missing in $VENDOR_DIR; lit cannot parse PDFs." >&2
  exit 1
fi

still_optional=$(missing_of "${OPTIONAL_TOOLS[@]}" | grep -v '^$' || true)
if [ -n "$still_optional" ]; then
  echo "Warning: optional bundled tools missing (skills fall back to installed copies): $(echo "$still_optional" | tr '\n' ' ')" >&2
fi

echo "Bundled tools ready in $VENDOR_DIR"
