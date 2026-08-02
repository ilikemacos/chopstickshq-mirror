#!/bin/bash
# ARENA terminal installer — plain macOS, no Xcode or dev tools required.
#   curl -fsSL https://chopstickshq.com/arena-fps/install.sh | bash
# Downloads the prebuilt app, installs to ~/Applications, clears the
# quarantine flag (skips the Gatekeeper right-click dance), and launches.
set -euo pipefail

URL="https://chopstickshq.com/arena-fps/ARENA-macOS.zip"
DEST="$HOME/Applications"

if [ "$(uname -s)" != "Darwin" ]; then
  echo "ARENA is a macOS game — this installer only runs on macOS." >&2
  exit 1
fi
if [ "$(uname -m)" != "arm64" ]; then
  echo "This build is Apple Silicon (arm64) only." >&2
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "▸ Downloading ARENA (2.2 MB)..."
curl -fsSL "$URL" -o "$TMP/ARENA.zip"

echo "▸ Installing to $DEST/ARENA.app..."
mkdir -p "$DEST"
rm -rf "$DEST/ARENA.app"
ditto -xk "$TMP/ARENA.zip" "$DEST"

# de-quarantine so first launch works without the right-click > Open dance
xattr -dr com.apple.quarantine "$DEST/ARENA.app" 2>/dev/null || true

echo "▸ Launching..."
open "$DEST/ARENA.app"
echo "Done. ARENA is installed at $DEST/ARENA.app"
