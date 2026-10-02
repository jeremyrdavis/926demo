#!/usr/bin/env bash
# Post one message to the team channel, ending with the same attribution the PR footer carries.
# Usage: bash ~/bin/slack-post.sh [--skill NAME] [--skill-version V] TEXT...
# Exits 0 without posting when Slack is not configured, so a sandbox launched without Slack still works.
set -u

skill=""
ver=""
while [ $# -gt 0 ]; do
  case "$1" in
    --skill) skill="$2"; shift 2 ;;
    --skill-version) ver="$2"; shift 2 ;;
    --) shift; break ;;
    *) break ;;
  esac
done
text="$*"

if [ -z "${SLACK_BOT_TOKEN:-}" ] || [ -z "${SLACK_CHANNEL_ID:-}" ]; then
  echo "slack-post: SLACK_BOT_TOKEN or SLACK_CHANNEL_ID not set; not posting" >&2
  exit 0
fi
if [ -z "$text" ]; then
  echo "usage: slack-post.sh [--skill NAME] [--skill-version V] TEXT..." >&2
  exit 2
fi

attr="_sandbox \`${SANDBOX_NAME:-unknown}\`"
[ -n "$skill" ] && attr="$attr · skill \`$skill\`${ver:+ v$ver}"
attr="$attr · model ${ANTHROPIC_MODEL:-Claude Code default} · $(date -u +'%Y-%m-%d %H:%M:%SZ')_"

if ! resp="$(curl -sS -X POST https://slack.com/api/chat.postMessage \
      -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
      --data-urlencode "channel=$SLACK_CHANNEL_ID" \
      --data-urlencode "text=$text"$'\n'"$attr" 2>&1)"; then
  echo "slack-post: curl failed: $resp" >&2
  exit 1
fi

python3 - "$resp" <<'PY'
import json, sys
raw = sys.argv[1]
try:
    d = json.loads(raw)
except ValueError:
    sys.exit("slack-post: non-JSON response: " + raw[:200])
if not d.get("ok"):
    sys.exit("slack-post: " + str(d.get("error", "unknown error")))
print(d.get("ts", ""))
PY
