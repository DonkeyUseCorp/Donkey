#!/usr/bin/env bash
#
# Vendors the arm64 command-line tools that Donkey's capability skills use into
# vendor/donkey-tools/, making each binary self-contained (its Homebrew dylibs are
# copied alongside and the install names are rewritten to @loader_path). The
# packaging step (scripts/package-donkey-app.sh -> stage_bundled_tools) then copies
# this directory into Donkey.app/Contents/Resources/donkey-tools/.
#
# The vendored binaries are large (~250MB) and are NOT committed to git — run this
# on the build machine before packaging. Re-runnable; each tool is independent, so
# one failure does not abort the rest.
#
# Requires: Homebrew, dylibbundler (installed automatically), network access.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
VENDOR_DIR="$ROOT_DIR/vendor/donkey-tools"
BREW_LIB="$(brew --prefix 2>/dev/null)/lib"

mkdir -p "$VENDOR_DIR"
STATUS=()

log() { printf '\n==> %s\n' "$*"; }
ok()  { STATUS+=("OK    $1"); }
fail(){ STATUS+=("FAIL  $1 ($2)"); echo "  ! $1: $2" >&2; }

ensure_brew_tool() {
  # $1 = formula, $2 = binary name to check
  command -v "$2" >/dev/null 2>&1 && return 0
  log "brew install $1"
  brew install "$1" >/dev/null 2>&1
}

# Extra dylib search dirs (besides Homebrew's lib) for the next bundle() call.
EXTRA_SEARCH=()

# Copy a binary into the vendor dir and bundle its dylibs flat (so @loader_path,
# which is relative to each file's own directory, resolves for binary->lib and
# lib->lib alike).
bundle() {
  # $1 = absolute source binary, $2 = vendored name
  local src="$1" name="$2"
  [ -f "$src" ] || { fail "$name" "source not found: $src"; return 1; }
  cp -f "$src" "$VENDOR_DIR/$name"
  chmod +x "$VENDOR_DIR/$name"
  local search=(--search-path "$BREW_LIB")
  local dir
  for dir in "${EXTRA_SEARCH[@]:-}"; do [ -n "$dir" ] && search+=(--search-path "$dir"); done
  dylibbundler --overwrite-files --bundle-deps --fix-file "$VENDOR_DIR/$name" \
    --dest-dir "$VENDOR_DIR" --install-path "@loader_path/" "${search[@]}" \
    >/dev/null 2>&1
  ok "$name"
}

# Build a TRUE LGPL ffmpeg from source — no --enable-gpl, no x264/x265. H.264/HEVC
# encode comes from Apple VideoToolbox; decode is built in; mp3 via LGPL libmp3lame,
# opus via BSD libopus, AV1 decode via BSD dav1d. Built shared, then dylibbundled.
# ffmpeg is MANDATORY: any failure here aborts the whole vendoring run, because a
# bundle without ffmpeg is not shippable.
build_lgpl_ffmpeg() {
  local ver="7.1.1"
  local work="/tmp/ffmpeg-lgpl-build"
  local brew_prefix; brew_prefix="$(brew --prefix)"
  command -v nasm >/dev/null 2>&1 || brew install nasm >/dev/null 2>&1
  command -v pkg-config >/dev/null 2>&1 || brew install pkg-config >/dev/null 2>&1
  local dep
  for dep in lame opus dav1d; do
    brew list "$dep" >/dev/null 2>&1 || brew install "$dep" >/dev/null 2>&1
  done
  rm -rf "$work"; mkdir -p "$work"
  curl -fsSL -o "$work/ffmpeg.tar.xz" "https://ffmpeg.org/releases/ffmpeg-${ver}.tar.xz" \
    || { echo "FATAL: ffmpeg source download failed" >&2; exit 1; }
  tar -xJf "$work/ffmpeg.tar.xz" -C "$work" --strip-components=1
  ( cd "$work" \
    && PKG_CONFIG_PATH="$brew_prefix/lib/pkgconfig:$brew_prefix/share/pkgconfig" \
       ./configure --prefix="$work/out" \
         --disable-gpl --disable-nonfree --disable-doc --disable-static --enable-shared \
         --enable-videotoolbox --enable-audiotoolbox \
         --enable-libmp3lame --enable-libopus --enable-libdav1d \
         --extra-cflags="-I$brew_prefix/include" --extra-ldflags="-L$brew_prefix/lib" \
    && make -j"$(sysctl -n hw.ncpu)" \
    && make install ) >"$work/build.log" 2>&1
  if [ ! -x "$work/out/bin/ffmpeg" ] || [ ! -x "$work/out/bin/ffprobe" ]; then
    echo "FATAL: LGPL ffmpeg build failed; tail of $work/build.log:" >&2
    tail -25 "$work/build.log" >&2
    exit 1
  fi
  EXTRA_SEARCH=("$work/out/lib")
  bundle "$work/out/bin/ffmpeg" ffmpeg
  bundle "$work/out/bin/ffprobe" ffprobe
  EXTRA_SEARCH=()
}

# Build liteparse's `lit` from source (Rust). It static-links leptonica+tesseract,
# so the result is a single self-contained binary (system libs only — no dylib
# bundling). MANDATORY: the pdf skill's extraction/OCR depends on it, and it
# replaces a separate tesseract.
build_liteparse() {
  command -v cargo >/dev/null 2>&1 || brew install rust >/dev/null 2>&1
  command -v cmake >/dev/null 2>&1 || brew install cmake >/dev/null 2>&1
  command -v cargo >/dev/null 2>&1 || { echo "FATAL: cargo unavailable for liteparse build" >&2; exit 1; }
  local root="/tmp/liteparse-build"
  rm -rf "$root"
  PKG_CONFIG_PATH="$(brew --prefix)/lib/pkgconfig" cargo install liteparse --root "$root" >"$root.log" 2>&1
  if [ ! -x "$root/bin/lit" ]; then
    echo "FATAL: liteparse (lit) build failed; tail of $root.log:" >&2
    tail -25 "$root.log" >&2
    exit 1
  fi
  cp -f "$root/bin/lit" "$VENDOR_DIR/lit"
  chmod +x "$VENDOR_DIR/lit"
  ok "lit"
}

log "Ensuring dylibbundler"
command -v dylibbundler >/dev/null 2>&1 || brew install dylibbundler >/dev/null 2>&1

# --- ffmpeg + ffprobe: mandatory, built LGPL from source (see build_lgpl_ffmpeg) ---
build_lgpl_ffmpeg

# --- liteparse `lit`: mandatory, built from source (self-contained, includes OCR) ---
build_liteparse

# --- qpdf (Homebrew) ---
if ensure_brew_tool qpdf qpdf; then
  bundle "$(brew --prefix qpdf)/bin/qpdf" qpdf
fi

# pandoc is intentionally NOT bundled. macOS's built-in `textutil` already converts
# among txt/html/rtf/doc/docx/odt (the common office formats), so the ~180MB pandoc
# binary isn't worth shipping. The `pdf` skill leads with textutil and uses pandoc
# only when the user happens to have it installed (markdown/LaTeX/EPUB).
#
# tesseract is no longer bundled separately: `lit` (liteparse) static-links its own
# Tesseract and is the pdf skill's extraction/OCR path.

# --- ImageMagick `magick` is intentionally NOT bundled. It loads coder modules
# (PNG/JPEG/etc.) and configuration at runtime from its install tree, which
# dylibbundler cannot relocate — a bundled copy fails with "no decode delegate".
# The `images` skill leads with `sips` (always present) and treats magick as an
# optional tool used only when the user has it installed. ---

# --- yt-dlp: official self-contained macOS build (bundles its own Python) ---
log "Downloading yt-dlp"
if curl -fsSL -o "$VENDOR_DIR/yt-dlp" \
  "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos"; then
  chmod +x "$VENDOR_DIR/yt-dlp"
  ok "yt-dlp"
else
  fail "yt-dlp" "download failed"
fi

# --- exiftool: standalone Perl distribution, runs via system /usr/bin/perl ---
log "Downloading exiftool"
if curl -fsSL -o /tmp/exiftool.tar.gz \
  "https://github.com/exiftool/exiftool/archive/refs/heads/master.tar.gz"; then
  rm -rf /tmp/exiftool-src "$VENDOR_DIR/exiftool" "$VENDOR_DIR/lib/Image"
  mkdir -p /tmp/exiftool-src
  tar -xzf /tmp/exiftool.tar.gz -C /tmp/exiftool-src --strip-components=1
  cp /tmp/exiftool-src/exiftool "$VENDOR_DIR/exiftool"
  chmod +x "$VENDOR_DIR/exiftool"
  mkdir -p "$VENDOR_DIR/lib"
  cp -R /tmp/exiftool-src/lib/. "$VENDOR_DIR/lib/"
  ok "exiftool"
else
  fail "exiftool" "download failed"
fi

log "Summary"
printf '%s\n' "${STATUS[@]}"
echo
echo "Vendored into: $VENDOR_DIR"
