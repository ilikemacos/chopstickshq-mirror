#!/bin/bash

set -Eeuo pipefail
IFS=$'\n\t'
umask 022

APP_NAME="cs.browser"
BUNDLE_ID="com.chopstickshq.csbrowser"
INSTALL_DIR="${CSBROWSER_PREFIX:-$HOME/Applications}"
REPO_URL="${CSBROWSER_REPO:-https://github.com/ilikemacos/cs.browser.git}"
REPO_REF="${CSBROWSER_REF:-main}"
MIN_MACOS_MAJOR=13
NODE_VERSION="${CSBROWSER_NODE:-22.17.0}"
INSTALL_URL="https://chopstickshq.com/browser/install.sh"

red()  { printf '\033[31m%s\033[0m\n' "$*" >&2; }
info() { printf '\033[38;5;110m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33mwarn:\033[0m %s\n' "$*" >&2; }
die()  { red "error: $*"; exit 1; }

cleanup() { [ -n "${TMP:-}" ] && [ -d "$TMP" ] && rm -rf "$TMP"; }
trap cleanup EXIT INT TERM

if [ "$(id -u)" = "0" ]; then
  die "do not run this installer as root or with sudo."
fi
[ "$(uname -s)" = "Darwin" ] || die "macOS only."
[ "$(uname -m)" = "arm64" ] || die "Apple silicon required (found $(uname -m))."

MACOS_MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
[ "$MACOS_MAJOR" -ge "$MIN_MACOS_MAJOR" ] || die "macOS $MIN_MACOS_MAJOR+ required."

MEM_GB=$(( $(sysctl -n hw.memsize) / 1073741824 ))
[ "$MEM_GB" -gt 6 ] || die "needs more than 6 GB RAM (found ~${MEM_GB} GB)."
[ "$MEM_GB" -le 8 ] && info "Low-RAM Mac (~${MEM_GB} GB) — Chromium process limits apply."

for tool in curl git tar mkdir ditto codesign; do
  command -v "$tool" >/dev/null 2>&1 || die "missing $tool"
done

TMP="$(mktemp -d "${TMPDIR:-/tmp}/csbrowser-build.XXXXXXXX")"
chmod 700 "$TMP"

node_major() { node -p "process.versions.node.split('.')[0]" 2>/dev/null || echo 0; }
if ! command -v node >/dev/null 2>&1 || [ "$(node_major)" -lt 20 ]; then
  info "Fetching Node $NODE_VERSION (user space)"
  curl -fSL --progress-bar "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-darwin-arm64.tar.gz" -o "$TMP/node.tgz"
  mkdir -p "$TMP/node"
  tar -xzf "$TMP/node.tgz" -C "$TMP/node" --strip-components=1
  export PATH="$TMP/node/bin:$PATH"
fi
info "Node $(node -v)"

SRC=""
if [ -f "${CSBROWSER_SRC:-}/package.json" ] && grep -q '"name": "cs.browser"' "${CSBROWSER_SRC}/package.json"; then
  SRC="$CSBROWSER_SRC"
  info "Using CSBROWSER_SRC: $SRC"
elif [ -f "$(pwd)/package.json" ] && grep -q '"name": "cs.browser"' "$(pwd)/package.json"; then
  SRC="$(pwd)"
  info "Using current directory: $SRC"
elif [ -f "$HOME/Projects/cs.browser/package.json" ] && grep -q '"name": "cs.browser"' "$HOME/Projects/cs.browser/package.json"; then
  SRC="$HOME/Projects/cs.browser"
  info "Using local checkout: $SRC"
else
  TARBALL_URL="${CSBROWSER_TARBALL:-https://chopstickshq.com/browser/cs.browser-src.tar.gz}"
  info "Fetching source from $TARBALL_URL"
  if curl -fSL --progress-bar "$TARBALL_URL" -o "$TMP/src.tar.gz"; then
    mkdir -p "$TMP/src"
    tar -xzf "$TMP/src.tar.gz" -C "$TMP/src" --strip-components=1 2>/dev/null \
      || tar -xzf "$TMP/src.tar.gz" -C "$TMP/src"
    SRC="$TMP/src"
    if [ ! -f "$SRC/package.json" ]; then
      FOUND="$(find "$TMP/src" -maxdepth 3 -name package.json -print -quit 2>/dev/null || true)"
      [ -n "$FOUND" ] || die "source archive did not contain package.json"
      SRC="$(dirname "$FOUND")"
    fi
  elif git clone --depth 1 --branch "$REPO_REF" "$REPO_URL" "$TMP/src" 2>/dev/null; then
    SRC="$TMP/src"
  else
    die "could not download source.
  Publish is at $TARBALL_URL
  Or run: CSBROWSER_SRC=\$HOME/Projects/cs.browser bash install.sh"
  fi
fi

info "Packing Chromium cs.browser.app…"
MAKE_BIN="/Library/Developer/CommandLineTools/usr/bin/make"
[ -x "$MAKE_BIN" ] || MAKE_BIN="make"
"$MAKE_BIN" -C "$SRC" pack

BUILT=""
for c in "$SRC/dist/mac-arm64/${APP_NAME}.app" "$SRC/dist/mac/${APP_NAME}.app"; do
  [ -d "$c" ] && BUILT="$c" && break
done
[ -n "$BUILT" ] || die "packed app missing"

mkdir -p "$INSTALL_DIR"
DEST="${INSTALL_DIR}/${APP_NAME}.app"
info "Installing ${DEST}"
rm -rf "${DEST}.old"
[ -e "$DEST" ] && mv "$DEST" "${DEST}.old" || true
ditto "$BUILT" "$DEST"
xattr -cr "$DEST" 2>/dev/null || true
codesign --force --sign - --timestamp=none "$DEST" >/dev/null 2>&1 || true
rm -rf "${DEST}.old" 2>/dev/null || true

info "Launching…"
open "$DEST"

cat <<EOF

  cs.browser is ready (Chromium).
  Location: ${DEST}

  Reinstall:
    curl -fsSL ${INSTALL_URL} | bash

EOF
