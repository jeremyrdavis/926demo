#!/usr/bin/env bash
# Read human-written messages from the team channel.
#   bash ~/bin/slack-read.sh --since TS              messages newer than TS, oldest first: ts<TAB>user<TAB>text
#   bash ~/bin/slack-read.sh --latest-prefix PREFIX  newest message starting with PREFIX, with the prefix removed
# Messages with bot_id or a subtype are dropped so agents never react to agents or to join/leave noise.
set -u

case "${1:-}" in
  --since) mode=since; arg="${2:-0}" ;;
  --latest-prefix) mode=prefix; arg="${2:-}" ;;
  *) echo "usage: slack-read.sh --since TS | --latest-prefix PREFIX" >&2; exit 2 ;;
esac

if [ -z "${SLACK_BOT_TOKEN:-}" ] || [ -z "${SLACK_CHANNEL_ID:-}" ]; then
  echo "slack-read: SLACK_BOT_TOKEN or SLACK_CHANNEL_ID not set" >&2
  exit 0
fi

oldest=0
[ "$mode" = since ] && oldest="$arg"

if ! resp="$(curl -sS -G https://slack.com/api/conversations.history \
      -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
      --data-urlencode "channel=$SLACK_CHANNEL_ID" \
      --data-urlencode "oldest=$oldest" \
      --data-urlencode "limit=50" \
      --data-urlencode "inclusive=false" 2>&1)"; then
  echo "slack-read: curl failed: $resp" >&2
  exit 1
fi

python3 - "$mode" "$arg" "$resp" <<'PY'
import html, json, sys
mode, arg, raw = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    d = json.loads(raw)
except ValueError:
    sys.exit("slack-read: non-JSON response: " + raw[:200])
if not d.get("ok"):
    sys.exit("slack-read: " + str(d.get("error", "unknown error")))
msgs = [m for m in d.get("messages", []) if not m.get("bot_id") and not m.get("subtype")]
msgs.sort(key=lambda m: float(m["ts"]))
def clean(m):
    return html.unescape(m.get("text", "")).replace("\t", " ").replace("\n", " ").strip()
if mode == "since":
    for m in msgs:
        print(f"{m['ts']}\t{m.get('user', '?')}\t{clean(m)}")
else:
    for m in reversed(msgs):
        t = clean(m)
        if t.lower().startswith(arg.lower()):
            print(t[len(arg):].strip())
            break
PY
