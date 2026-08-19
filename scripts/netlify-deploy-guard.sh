#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SITE="$(cd "$SCRIPT_DIR/.." && pwd)"
WORK_ROOT="$(cd "$SITE/.." && pwd)"
NETLIFY="${NETLIFY:-$WORK_ROOT/rnitro-site/node_modules/.bin/netlify}"
MIN_CREDITS="${MIN_CREDITS:-100}"

source "$SCRIPT_DIR/netlify-credits.sh"

CREDITS="$(netlify_credits_remaining "$NETLIFY")"

if [ "$CREDITS" = "unknown" ] || [ -z "$CREDITS" ]; then
  echo "REFUSED: cannot read Netlify credits (need >= $MIN_CREDITS to deploy)" >&2
  echo "Check https://app.netlify.com/teams/*/billing and retry when balance >= $MIN_CREDITS" >&2
  exit 1
fi

if [ "$CREDITS" -lt "$MIN_CREDITS" ]; then
  echo "REFUSED: $CREDITS Netlify credits remaining (minimum $MIN_CREDITS)" >&2
  echo "Deploy blocked even with explicit instruction. Top up credits first." >&2
  exit 1
fi

VERIFY="$SCRIPT_DIR/verify-chopsticks-ai-release.sh"
if [ -f "$VERIFY" ]; then
  bash "$VERIFY" "$SITE" || exit 1
fi

if [ "$#" -gt 0 ]; then
  ( cd "$SITE" && exec "$NETLIFY" "$@" )
fi

echo "OK: $CREDITS Netlify credits remaining (>= $MIN_CREDITS floor)"
