#!/usr/bin/env bash
# Local socket-mode run: reads credentials from .env, state dir as $1.
#
#   ./run-slack-dev.sh ~/dev/smeggdrop-state/hardchats
#
# .env needs SLACK_BOT_TOKEN and SLACK_APP_TOKEN (see README).
set -euo pipefail
cd "$(dirname "$0")"

STATE="${1:-state-local}"

if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  . ./.env
  set +a
fi

: "${SLACK_BOT_TOKEN:?set SLACK_BOT_TOKEN in .env}"
: "${SLACK_APP_TOKEN:?set SLACK_APP_TOKEN in .env}"

exec uv run --extra slack smeggdrop --state "$STATE" slack
