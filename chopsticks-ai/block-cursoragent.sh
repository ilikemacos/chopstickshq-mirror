#!/usr/bin/env bash
set -Eeuo pipefail

CURSOR_TRAILER='^Co-authored-by: Cursor <cursoragent@cursor.com>'
CURSOR_EMAIL='cursoragent@cursor.com'
GITHUB_AUTHOR_NAME='ilikemacos'
GITHUB_AUTHOR_EMAIL='287112028+ilikemacos@users.noreply.github.com'

MODE=local
FIX_GITHUB=auto
GITHUB_REPO=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --global) MODE=global ;;
    --local) MODE=local ;;
    --fix-github)
      FIX_GITHUB=yes
      if [[ "${2:-}" == *