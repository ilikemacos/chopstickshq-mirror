#!/usr/bin/env bash
set -euo pipefail

SITE="${1:?usage: verify-chopsticks-ai-release.sh <site-dir>}"
VJ="$SITE/chopsticks-ai/version.json"

if [[ ! -f "$VJ" ]]; then
  echo "REFUSED: missing $VJ" >&2
  exit 1
fi

read -r latest zip sha <<<"$(
  PY="$(command -v python3.11 2>/dev/null || command -v python3 2>/dev/null || echo /usr/bin/python3)"
  "$PY" - "$VJ" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    data = json.load(f)
rel = (data.get("releases") or {}).get("stable") or {}
print(data.get("latest", ""), rel.get("zip", ""), rel.get("sha256", ""))
PY
)"

if [[ -z "$zip" || -z "$sha" ]]; then
  echo "REFUSED: version.json missing releases.stable.zip or sha256" >&2
  exit 1
fi

ZIP_PATH="$SITE/chopsticks-ai/$zip"
if [[ ! -f "$ZIP_PATH" ]]; then
  echo "REFUSED: zip missing on disk: $ZIP_PATH (manifest lists $zip for cs.AI $latest)" >&2
  exit 1
fi

ACTUAL="$(shasum -a 256 "$ZIP_PATH" | awk '{print $1}')"
if [[ "$ACTUAL" != "$sha" ]]; then
  echo "REFUSED: sha256 mismatch for $zip" >&2
  echo "  version.json: $sha" >&2
  echo "  file on disk: $ACTUAL" >&2
  echo "Rebuild with ./build-app.sh v$latest and redeploy." >&2
  exit 1
fi

echo "OK: cs.AI $latest — $zip sha256 verified"
