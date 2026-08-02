#!/bin/bash
set -Eeuo pipefail
echo "🚀 Fathom Pro Installer"
[[ "$(uname)" == "Darwin" ]] || { echo "macOS only"; exit 1; }
[[ "${EUID:-$(id -u)}" -ne 0 ]] || { echo "Do not run as root"; exit 1; }
VER="v0.1.0-Pro-Beta"
URL="https://chopstickshq.com/fathom-pro/FathomPro-${VER}.zip"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fathom-pro-install.XXXXXX")
trap 'rm -rf -- "$TMP"' EXIT
echo "Downloading $URL…"
curl --progress-bar -fL "$URL" -o "$TMP/fp.zip"
unzip -qo "$TMP/fp.zip" -d "$TMP/out"
mkdir -p "$HOME/Applications"
rm -rf "$HOME/Applications/Fathom Pro.app"
ditto "$TMP/out/Fathom Pro.app" "$HOME/Applications/Fathom Pro.app"
xattr -cr "$HOME/Applications/Fathom Pro.app" 2>/dev/null || true
codesign --force --deep --sign - "$HOME/Applications/Fathom Pro.app" 2>/dev/null || true
echo "✅ Installed ~/Applications/Fathom Pro.app"
echo "Unlock: find the hidden code on chopstickshq.com → paste into Fathom Pro
open "$HOME/Applications/Fathom Pro.app"
