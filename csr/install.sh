#!/bin/bash
# Chopsticks HQ — CSR (Chopsticks Super Resolution) installer, macOS Apple silicon
#   curl -fsSL https://chopstickshq.com/csr/install.sh | bash
# No sudo. No Xcode. Installs into /Applications, or ~/Applications if that is
# not writable.
set -euo pipefail

VERSION="1.0"
BASE="${CSR_BASE:-https://chopstickshq.com/csr}"
ZIP_SHA="1e0f3dc494d107dc03176dfec044ea826fb57070ae4a1016383f149ff4b83c30"

bold() { printf '\033[1m%s\033[0m\n' "$1"; }
info() { printf '  %s\n' "$1"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }
die()  { printf '\n\033[31m✗ %s\033[0m\n\n' "$1" >&2; exit 1; }

echo
bold "CSR $VERSION — Chopsticks Super Resolution"
echo

# --- 1. Check the machine ----------------------------------------------------
[ "$(uname -s)" = "Darwin" ] || die "This installer is macOS only (found $(uname -s))."

ARCH="$(uname -m)"
if [ "$ARCH" != "arm64" ]; then
  die "Apple silicon only. This Mac reports '$ARCH'.
   CSR needs MetalFX and the unified-memory zero-copy capture path, neither of
   which exists on Intel Macs."
fi

# A shell under Rosetta misreports the architecture, so check explicitly.
if [ "$(sysctl -n sysctl.proc_translated 2>/dev/null || echo 0)" = "1" ]; then
  die "This shell is running under Rosetta. Open a native arm64 Terminal and re-run."
fi

MACOS="$(sw_vers -productVersion)"
MAJOR="${MACOS%%.*}"
[ "$MAJOR" -ge 14 ] || die "macOS 14 or later required (found $MACOS)."
ok "macOS $MACOS on Apple silicon"

# --- 2. Pick a destination ---------------------------------------------------
# /Applications is preferred, but it is not writable on managed Macs and this
# installer never uses sudo — so fall back to the per-user location that macOS
# treats identically.
if [ -w "/Applications" ]; then
  DEST="/Applications"
else
  DEST="$HOME/Applications"
  mkdir -p "$DEST"
  warn "/Applications is not writable; installing to $DEST instead."
fi
APP="$DEST/CSR.app"

# --- 3. Download and verify --------------------------------------------------
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

info "Downloading CSR ${VERSION}…"
curl -fsSL "$BASE/CSR-$VERSION.zip" -o "$TMP/CSR.zip" \
  || die "Download failed. Check your connection and try again."

# Verify before touching anything on disk. A truncated or tampered download must
# fail here, not halfway through replacing a working install.
GOT="$(shasum -a 256 "$TMP/CSR.zip" | cut -d' ' -f1)"
[ "$GOT" = "$ZIP_SHA" ] || die "Checksum mismatch — the download was discarded.
   expected $ZIP_SHA
   got      $GOT"
ok "Downloaded and verified ($(du -h "$TMP/CSR.zip" | cut -f1))"

# --- 4. Install --------------------------------------------------------------
# ditto, not unzip: it preserves the bundle's symlinks, permissions and resource
# forks. A plain unzip breaks the code signature.
ditto -x -k "$TMP/CSR.zip" "$TMP/unpacked" || die "Could not unpack the archive."
[ -x "$TMP/unpacked/CSR.app/Contents/MacOS/CSR" ] \
  || die "The archive did not contain a usable CSR.app."

if [ -e "$APP" ]; then
  info "Replacing the existing install at ${APP}…"
  rm -rf "$APP"
fi
ditto "$TMP/unpacked/CSR.app" "$APP" || die "Could not install to $DEST."

# The app is ad-hoc signed, so without this macOS shows the "unidentified
# developer" dialog on first launch.
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
ok "Installed to $APP"

# --- 5. Verify the install actually runs -------------------------------------
# CSR ships a headless self-test; running it here means the installer reports a
# working GPU pipeline rather than just "files copied".
if "$APP/Contents/MacOS/CSR" --selftest >/dev/null 2>&1; then
  ok "Self-test passed — Metal pipeline and all upscaling backends are working"
else
  warn "Self-test reported a problem. CSR is installed; run this to see why:"
  info "  $APP/Contents/MacOS/CSR --selftest"
fi

echo
bold "Done."
info "Launch it:   open -a CSR"
info "Or run:      open $APP"
echo
info "macOS will ask for Screen Recording permission on first capture."
info "That single permission is worded \"screen and audio\" by macOS because it"
info "covers both; CSR never captures audio."
echo
