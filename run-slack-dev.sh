#!/usr/bin/env bash
# Run the slack bot locally over Socket Mode: no public endpoint, state on
# disk, safe to Ctrl-C.
#
#   ./run-slack-dev.sh [state-dir]      # defaults to ./state-local
#
# .env (gitignored) needs SLACK_BOT_TOKEN and SLACK_APP_TOKEN — see the
# README's Slack section for how to mint them.
#
# "Safely" here means:
#   - refuses to start a second instance against the same state dir. The
#     versioned-eval persistence assumes one writer; two bots racing on the
#     same files is exactly the kind of self-inflicted corruption that
#     happened during dev when a repl and a running bot touched the same
#     state at once.
#   - the process memory cap (smeggdrop.hardening, default 2048MB) is
#     always on for the slack subcommand — a single hostile eval can't take
#     the host down with it.
#   - state is a plain directory, so it's just files: `git status` in it
#     before trusting a session, and you can always restore from a backup
#     or the state repo's own history if a bad eval writes something
#     unwanted.
set -euo pipefail
cd "$(dirname "$0")"

STATE="${1:-state-local}"
mkdir -p "$STATE"
LOCK="$STATE/.smeggdrop.lock"

if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  . ./.env
  set +a
fi

: "${SLACK_BOT_TOKEN:?set SLACK_BOT_TOKEN in .env}"
: "${SLACK_APP_TOKEN:?set SLACK_APP_TOKEN in .env}"

exec 9>"$LOCK"
if ! flock -n 9; then
  echo "error: another smeggdrop instance already holds the lock on $STATE" >&2
  echo "       (check: pgrep -af 'smeggdrop.*--state $STATE')" >&2
  exit 1
fi

commit="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
echo "smeggdrop @ $commit ($branch) — state: $STATE — memory cap: ${SMEGGDROP_MEMORY_MB:-2048}MB"

exec uv run --extra slack smeggdrop --state "$STATE" slack
