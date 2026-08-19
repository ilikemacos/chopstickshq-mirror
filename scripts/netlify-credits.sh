#!/usr/bin/env bash
netlify_credits_remaining() {
  local netlify="${1:-}"
  if [ -z "$netlify" ]; then
    netlify="${NETLIFY:-}"
  fi
  if [ -z "$netlify" ] || [ ! -x "$netlify" ]; then
    netlify="$(command -v netlify 2>/dev/null || true)"
  fi
  if [ -z "$netlify" ] || [ ! -x "$netlify" ]; then
    local work_root="${RNITRO_SITE_WORK:-/Users/mehmeh/rnitro-site-work}"
    netlify="$work_root/rnitro-site/node_modules/.bin/netlify"
  fi
  if [ ! -x "$netlify" ]; then
    echo "unknown"
    return 1
  fi

  local py="${PYTHON:-}"
  if [ -z "$py" ]; then
    py="$(command -v python3.11 2>/dev/null || command -v python3 2>/dev/null || true)"
  fi
  if [ -z "$py" ]; then
    echo "unknown"
    return 1
  fi

  "$netlify" api listAccountsForUser 2>/dev/null | "$py" -c '
import sys, json
try:
    c = json.load(sys.stdin)[0]["capabilities"]["credits"]
    print(max(0, int(c["included"]) - int(c["used"])))
except Exception:
    print("unknown")
' 2>/dev/null
}
