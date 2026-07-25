#!/usr/bin/env bash
# Tell a running bot (started by run-slack-dev.sh) to reload state from
# disk without dropping its Slack connection or restarting the process.
#
#   ./reload-bot.sh [state-dir]      # defaults to ./state-local
#
# Use this after editing state some other way (a one-off `smeggdrop repl`
# fix) while the bot is up: the reload is queued on the same worker thread
# evals run on, so it can't interrupt one in flight, and the socket-mode
# connection to Slack is never touched.
#
# Caveat: reload only re-syncs the bot's in-memory copy with whatever is on
# disk. The file state store has no cross-process locking, so if a repl
# edit and a live Slack eval write at the exact same instant, the second
# write still wins — reload doesn't add coordination that isn't already
# there. Fine for a quick one-off fix; not a substitute for the S3 store's
# conditional writes if that ever matters here.
set -euo pipefail
cd "$(dirname "$0")"

STATE="${1:-state-local}"
PIDFILE="$STATE/.smeggdrop.pid"

if [[ ! -f "$PIDFILE" ]]; then
  echo "error: no pidfile at $PIDFILE — is the bot running against $STATE?" >&2
  exit 1
fi

pid="$(cat "$PIDFILE")"
if ! kill -0 "$pid" 2>/dev/null; then
  echo "error: pidfile $PIDFILE points at pid $pid, which isn't running (stale)" >&2
  exit 1
fi

kill -HUP "$pid"
echo "sent reload signal to pid $pid"
