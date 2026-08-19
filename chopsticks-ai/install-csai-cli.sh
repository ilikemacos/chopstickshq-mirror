#!/usr/bin/env bash
set -euo pipefail

BASE="${CS_AI_CLI_BASE:-https://chopstickshq.com/chopsticks-ai/cli}"
DEST_DIR="${CS_AI_CLI_HOME:-$HOME/.local/share/chopsticks-ai-cli}"
NAME="csai"

echo "Installing cs.AI CLI…"
mkdir -p "$DEST_DIR"
curl -fsSL "$BASE/csai" -o "$DEST_DIR/csai"
curl -fsSL "$BASE/csai.py" -o "$DEST_DIR/csai.py"
curl -fsSL "$BASE/csai_tui.py" -o "$DEST_DIR/csai_tui.py"
curl -fsSL "$BASE/csai_client.py" -o "$DEST_DIR/csai_client.py"
curl -fsSL "$BASE/csai_update.py" -o "$DEST_DIR/csai_update.py"
chmod +x "$DEST_DIR/csai" "$DEST_DIR/csai.py"

mkdir -p "$HOME/bin"
ln -sf "$DEST_DIR/csai" "$HOME/bin/$NAME"

PATH_LINE='export PATH="$HOME/bin:$PATH"'
PROFILE=""
for candidate in "$HOME/.zshrc" "$HOME/.zprofile" "$HOME/.bash_profile"; do
  if [[ -f "$candidate" ]] || [[ "$candidate" == "$HOME/.zshrc" ]]; then
    PROFILE="$candidate"
    break
  fi
done
if [[ -n "$PROFILE" ]]; then
  touch "$PROFILE"
  if ! grep -qF '$HOME/bin' "$PROFILE" 2>/dev/null; then
    {
      echo ""
      echo "# cs.AI CLI"
      echo "$PATH_LINE"
    } >> "$PROFILE"
    echo "✅ Added ~/bin to PATH in $PROFILE"
  fi
fi

echo ""
echo "✅ cs.AI CLI installed to $DEST_DIR/csai"
echo ""
echo "Restart Terminal or run:  source ${PROFILE:-~/.zshrc}"
echo "Then:  csai          # full-screen terminal UI"
echo "       csai --plain  # simple line prompt"
echo "       csai update   # self-update from chopstickshq.com"
