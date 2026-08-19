#!/usr/bin/env bash
set -euo pipefail
echo "Fathom Pro Installer"
VER="v0.1.0-Pro-Beta"
URL="https://chopstickshq.com/fathom-pro/FathomPro-${VER}.zip"
GH_URL="https://github.com/ilikemacos/Fathom-Pro/releases/latest/download/FathomPro-${VER}.zip"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fathom-pro-install.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
echo "Downloading…"
if ! curl -fsSL "$URL" -o "$TMP/f.zip" 2>/dev/null; then
  curl -fsSL "$GH_URL" -o "$TMP/f.zip"
fi
unzip -q "$TMP/f.zip" -d "$TMP/out"
rm -rf "$HOME/Applications/Fathom Pro.app"
ditto "$TMP/out/Fathom Pro.app" "$HOME/Applications/Fathom Pro.app"
xattr -cr "$HOME/Applications/Fathom Pro.app" 2>/dev/null || true
codesign --force --deep --sign - "$HOME/Applications/Fathom Pro.app" 2>/dev/null || true
echo "Installed ~/Applications/Fathom Pro.app"
echo "Unlock: vault keys or homepage scavenger (first L in Small)"
open "$HOME/Applications/Fathom Pro.app"
