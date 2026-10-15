#!/usr/bin/env bash
#
# Post a message into a channel as the operator, not as a tcl eval.
#
# Reuses the bot's own token (already has chat:write) rather than a
# separate app -- this is an operator/dev tool run from a terminal, not
# something reachable from the sandbox, so it adds no new attack surface.
#
#   ./notify-slack.sh "message text"
#   ./notify-slack.sh -c C1234567 "message text"   # override channel
#
# Plain text (no code fence), so it reads visually distinct from a proc's
# ```-fenced``` eval output and isn't mistaken for the bot itself talking.
set -euo pipefail
cd "$(dirname "$0")"

CHANNEL="${SMEGGDROP_NOTIFY_CHANNEL:-C03QKEXDS}"
if [ "${1:-}" = "-c" ]; then
    CHANNEL="$2"
    shift 2
fi
TEXT="${1:?usage: $0 [-c CHANNEL] \"message text\"}"

TOKEN=$(grep '^SLACK_BOT_TOKEN=' .env | cut -d= -f2-)
[ -n "$TOKEN" ] || { echo "no SLACK_BOT_TOKEN in .env" >&2; exit 1; }

PAYLOAD=$(python3 -c '
import json, sys
print(json.dumps({
    "channel": sys.argv[1],
    "text": sys.argv[2],
    "unfurl_links": False,
    "unfurl_media": False,
}))
' "$CHANNEL" "$TEXT")

if ! RESP=$(curl -sS -X POST https://slack.com/api/chat.postMessage \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json; charset=utf-8" \
    -d "$PAYLOAD"); then
    echo "FAILED: request to slack didn't complete (network/curl error)" >&2
    exit 1
fi

# a network hiccup or a slack-side 5xx can return an empty or non-json body,
# which json.loads would otherwise surface as a raw traceback
python3 -c '
import json, sys
raw = sys.argv[1]
try:
    d = json.loads(raw)
except json.JSONDecodeError:
    print(f"FAILED: non-json response from slack: {raw[:200]!r}", file=sys.stderr)
    sys.exit(1)
if not d.get("ok"):
    print("FAILED:", d.get("error"), file=sys.stderr)
    sys.exit(1)
print("posted", d.get("ts"), "to", d.get("channel"))
' "$RESP"
