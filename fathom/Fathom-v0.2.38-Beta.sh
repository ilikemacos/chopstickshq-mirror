#!/bin/bash
set -Eeuo pipefail
echo "🚀 Fathom Installer (App ZIP)"
[[ "$(uname)" == "Darwin" ]] || { echo "macOS only"; exit 1; }
[[ "${EUID:-$(id -u)}" -ne 0 ]] || { echo "Do not run as root"; exit 1; }
VER="v0.2.38-Beta"
URL="https://chopstickshq.com/fathom/Fathom-${VER}.zip"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fathom-install.XXXXXX")
trap 'rm -rf -- "$TMP"' EXIT
echo "Downloading $URL…"
curl --progress-bar -fL "$URL" -o "$TMP/fathom.zip"
unzip -qo "$TMP/fathom.zip" -d "$TMP/out"
mkdir -p "$HOME/Applications"
rm -rf "$HOME/Applications/Fathom.app"
ditto "$TMP/out/Fathom.app" "$HOME/Applications/Fathom.app"
xattr -cr "$HOME/Applications/Fathom.app" 2>/dev/null || true
codesign --force --deep --sign - "$HOME/Applications/Fathom.app" 2>/dev/null || true
echo "✅ Installed ~/Applications/Fathom.app"
open "$HOME/Applications/Fathom.app"
