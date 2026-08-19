#!/bin/bash
# Chopsticks HQ — Upscaler installer (macOS, Apple silicon)
#   curl -fsSL https://chopstickshq.com/upscaler/install.sh | bash
# No sudo. No Xcode. Installs under $HOME only.
set -euo pipefail

VERSION="0.1.0"
BASE="${UPSCALER_BASE:-https://chopstickshq.com/upscaler}"
APP_SHA="d2e8ec07979961dcd88da6c8e0074c860866e17b46fcd9da2ce452f42c14cd0f"
MACAPP_SHA="7ce5299c5584addab97808a78b387b4d1799a28365852a15d0313759fa0b0fe9"

PY_URL="https://github.com/astral-sh/python-build-standalone/releases/download/20260814/cpython-3.11.16%2B20260814-aarch64-apple-darwin-install_only.tar.gz"
PY_SHA="fcba9f3f676c83e07225e38116649f0c6eb94cb4fcc166632cf92769462b6e39"

PREFIX="$HOME/.local/share/chopsticks-upscaler"
BINDIR="$HOME/.local/bin"

bold() { printf '\033[1m%s\033[0m\n' "$1"; }
info() { printf '  %s\n' "$1"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }
die()  { printf '\n\033[31m✗ %s\033[0m\n\n' "$1" >&2; exit 1; }

echo
bold "Upscaler $VERSION — Chopsticks HQ"
echo

# --- 1. Check the machine -----------------------------------------------------
[ "$(uname -s)" = "Darwin" ] || die "This installer is macOS only (found $(uname -s))."

ARCH="$(uname -m)"
if [ "$ARCH" != "arm64" ]; then
  die "Apple silicon only. This Mac reports '$ARCH' (Intel is not supported).
   The model runs through CoreML on the Neural Engine / GPU, which Intel Macs do not have."
fi

# Guard against Rosetta: a translated shell reports arm64's sibling incorrectly.
if [ "$(sysctl -n sysctl.proc_translated 2>/dev/null || echo 0)" = "1" ]; then
  die "This shell is running under Rosetta. Open a native arm64 Terminal and re-run."
fi

MACOS="$(sw_vers -productVersion)"
MAJOR="${MACOS%%.*}"
[ "$MAJOR" -ge 13 ] || die "macOS 13 or later required (found $MACOS)."
ok "macOS $MACOS on Apple silicon ($(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo arm64))"

FREE_KB="$(df -k "$HOME" | awk 'NR==2 {print $4}')"
[ "$FREE_KB" -gt 1500000 ] || die "Needs ~1.5 GB free in $HOME (found $((FREE_KB / 1024)) MB)."

# --- 2. Find a usable Python --------------------------------------------------
PYTHON=""
for cand in python3.13 python3.12 python3.11 python3; do
  path="$(command -v "$cand" 2>/dev/null)" || continue
  # The Xcode CLT stub exits non-zero until its licence is accepted — skip it.
  ver="$("$path" -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null)" || continue
  case "$ver" in
    3.1[0-9]*) PYTHON="$path"; break ;;
  esac
done

if [ -n "$PYTHON" ]; then
  ok "Using $PYTHON ($("$PYTHON" -c 'import platform; print(platform.python_version())'))"
else
  info "No usable Python found — fetching a private one (~27 MB, not added to PATH)"
  TMP_PY="$(mktemp -d)"
  trap 'rm -rf "$TMP_PY"' EXIT
  curl -fsSL "$PY_URL" -o "$TMP_PY/python.tar.gz" || die "Could not download Python."
  GOT="$(shasum -a 256 "$TMP_PY/python.tar.gz" | awk '{print $1}')"
  [ "$GOT" = "$PY_SHA" ] || die "Python checksum mismatch (expected $PY_SHA, got $GOT)."
  mkdir -p "$PREFIX"
  rm -rf "$PREFIX/python"
  tar -xzf "$TMP_PY/python.tar.gz" -C "$PREFIX"   # unpacks to $PREFIX/python
  PYTHON="$PREFIX/python/bin/python3"
  [ -x "$PYTHON" ] || die "Python unpacked but $PYTHON is missing."
  ok "Private Python ready (checksum verified)"
fi

# --- 3. Fetch the app ---------------------------------------------------------
TMP_APP="$(mktemp -d)"
trap 'rm -rf "$TMP_APP" ${TMP_PY:-}' EXIT
info "Downloading Upscaler $VERSION"
curl -fsSL "$BASE/upscaler-$VERSION.tar.gz" -o "$TMP_APP/app.tar.gz" || die "Download failed."
GOT="$(shasum -a 256 "$TMP_APP/app.tar.gz" | awk '{print $1}')"
[ "$GOT" = "$APP_SHA" ] || die "Checksum mismatch (expected $APP_SHA, got $GOT). Nothing was installed."
ok "Download verified (SHA-256)"

mkdir -p "$PREFIX"
rm -rf "$PREFIX/app"
tar -xzf "$TMP_APP/app.tar.gz" -C "$TMP_APP"
mv "$TMP_APP/upscaler-$VERSION" "$PREFIX/app"

# --- 4. Environment + dependencies -------------------------------------------
info "Building environment (this pulls ~120 MB from PyPI, once)"
"$PYTHON" -m venv "$PREFIX/venv" >/dev/null
"$PREFIX/venv/bin/python" -m pip install --quiet --upgrade pip >/dev/null
if ! "$PREFIX/venv/bin/python" -m pip install --quiet -r "$PREFIX/app/requirements.txt"; then
  die "Dependency install failed. Nothing else was changed."
fi
ok "ONNX Runtime + Gradio installed"

# --- 5. Launcher --------------------------------------------------------------
mkdir -p "$BINDIR"
cat > "$BINDIR/upscaler" <<LAUNCHER
#!/bin/bash
# Chopsticks HQ Upscaler $VERSION
PREFIX="\$HOME/.local/share/chopsticks-upscaler"
cd "\$PREFIX/app" || exit 1
case "\${1:-ui}" in
  ui)     exec "\$PREFIX/venv/bin/python" app.py ;;
  image)  shift; exec "\$PREFIX/venv/bin/python" -m upscaler.image "\$@" ;;
  video)  shift; exec "\$PREFIX/venv/bin/python" -m upscaler.video "\$@" ;;
  --help|-h)
    echo "upscaler            open the web UI (http://127.0.0.1:7860)"
    echo "upscaler image ...  upscale one image  (--input --output --scale 2|4)"
    echo "upscaler video ...  upscale a video    (--input --output --resolution 1080p)"
    echo "upscaler uninstall  remove everything"
    ;;
  uninstall)
    rm -rf "\$PREFIX" "\$HOME/.cache/video-upscaler" "\$HOME/Applications/Upscaler.app" "\$HOME/.local/bin/upscaler"
    echo "Upscaler removed."
    ;;
  *) exec "\$PREFIX/venv/bin/python" -m upscaler.image "\$@" ;;
esac
LAUNCHER
chmod +x "$BINDIR/upscaler"
ok "Installed $BINDIR/upscaler"

# --- 6. SwiftUI app -----------------------------------------------------------
info "Installing Upscaler.app"
if curl -fsSL "$BASE/Upscaler-$VERSION.zip" -o "$TMP_APP/Upscaler.zip" 2>/dev/null; then
  GOT="$(shasum -a 256 "$TMP_APP/Upscaler.zip" | awk '{print $1}')"
  if [ "$GOT" = "$MACAPP_SHA" ]; then
    mkdir -p "$HOME/Applications"
    rm -rf "$HOME/Applications/Upscaler.app"
    if ditto -x -k "$TMP_APP/Upscaler.zip" "$HOME/Applications" 2>/dev/null; then
      # Unsigned build: clear quarantine only if the transfer set it, so the
      # app opens normally instead of failing with a misleading "damaged" error.
      xattr -dr com.apple.quarantine "$HOME/Applications/Upscaler.app" 2>/dev/null || true
      ok "Upscaler.app → ~/Applications"
    else
      warn "Could not unpack Upscaler.app — the CLI still works."
    fi
  else
    warn "Upscaler.app checksum mismatch — skipped. The CLI still works."
  fi
else
  warn "Upscaler.app not available — the CLI still works."
fi

# --- 7. Optional pieces -------------------------------------------------------
if command -v ffmpeg >/dev/null 2>&1; then
  ok "FFmpeg found — video upscaling enabled"
else
  warn "FFmpeg not found — image upscaling works, video does not."
  info "  Install it with: brew install ffmpeg"
fi

case ":$PATH:" in
  *":$BINDIR:"*) ;;
  *)
    warn "$BINDIR is not on your PATH. Add it with:"
    info "  echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.zshrc && exec zsh"
    ;;
esac

echo
bold "Done."
info "Upscaler.app          → ~/Applications (native SwiftUI)"
info "upscaler              → web UI at http://127.0.0.1:7860"
info "upscaler image -i in.png -o out.png -s 4"
info "upscaler video -i in.mp4 -o out.mp4 -r 1080p"
info "upscaler uninstall    → removes everything it installed"
echo
info "Model weights (~68 MB) download on first use and cache in ~/.cache/video-upscaler."
echo
