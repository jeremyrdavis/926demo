#!/usr/bin/env bash
# Reviewer sandbox loop: poll GitHub for open PRs, review each new one with Claude Code under the
# code-review skill, and post the review with a traceability footer. The agent only writes a file;
# this script posts to GitHub and Slack. Slack is also an inbox: humans can ask for a re-review.
#
# set -u, not set -e: one failed review must not kill the loop.
set -u

REPO="${REPO:-}"
POLL_SECONDS="${POLL_SECONDS:-30}"
REVIEWER_HOME="${REVIEWER_HOME:-/home/agent}"

SKILL_NAME="code-review"
SKILL_VERSION="1.0.0"
# Set REVIEWER_LOCKED_DOWN=1 only when the GitHub token really cannot push
# (bot PAT or a proxy deny on git-receive-pack); the footer must stay honest.
REVIEWER_LOCKED_DOWN="${REVIEWER_LOCKED_DOWN:-0}"
SANDBOX_LABEL="${SANDBOX_NAME:-reviewer}"
MODEL_LABEL="${ANTHROPIC_MODEL:-Claude Code default}"
SBX_VERSION="${SBX_VERSION:-unknown}"
MAX_ATTEMPTS=3

STATE_DIR="$REVIEWER_HOME/state"
STATE_FILE="$STATE_DIR/handled.txt"
SLACK_CURSOR="$STATE_DIR/slack-cursor"
REVIEWS_DIR="$REVIEWER_HOME/reviews"
LOGS_DIR="$REVIEWER_HOME/logs"
WORK_DIR="$REVIEWER_HOME/workspace"
BIN_DIR="$REVIEWER_HOME/bin"
STARTED_AT=$(date +%s)

log() {
  printf '%s [reviewer] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

if [ -z "$REPO" ]; then
  log "REPO is not set (launch with -e REPO=<owner>/<repo>)" >&2
  exit 2
fi

mkdir -p "$STATE_DIR" "$REVIEWS_DIR" "$LOGS_DIR" "$WORK_DIR"
touch "$STATE_FILE"
# Start reading Slack from now so commands typed before this process existed are not replayed.
[ -s "$SLACK_CURSOR" ] || date +%s >"$SLACK_CURSOR"

declare -A attempts

slack_post() {
  bash "$BIN_DIR/slack-post.sh" --skill "$SKILL_NAME" --skill-version "$SKILL_VERSION" "$@" >/dev/null \
    || log "slack post failed (continuing)"
}

footer() {
  local n="$1" author="$2"
  printf -- '---\n'
  printf '_Reviewed by `%s` · sandbox `%s` · skill `%s` v%s · model %s · triggered by PR #%s opened by @%s · %s · Docker Sandboxes %s_\n' \
    "$BOT_LOGIN" "$SANDBOX_LABEL" "$SKILL_NAME" "$SKILL_VERSION" "$MODEL_LABEL" \
    "$n" "$author" "$(date -u +'%Y-%m-%d %H:%M:%SZ')" "$SBX_VERSION"
  if [ "$REVIEWER_LOCKED_DOWN" = "1" ]; then
    printf '_This agent can read code and comment. It cannot push, approve, or merge._\n'
  else
    printf '_This agent is configured to comment only. It currently runs with @%s'"'"'s GitHub permissions._\n' "$BOT_LOGIN"
  fi
}

# First content line after a **Heading** in the review file.
section_first_line() {
  awk -v h="$2" 'found && NF { print; exit } tolower($0) ~ "^\\*\\*" tolower(h) "\\*\\*" { found=1 }' "$1"
}

blocking_summary() {
  local first
  first="$(section_first_line "$1" "Blocking")"
  case "$(printf '%s' "$first" | tr '[:upper:]' '[:lower:]')" in
    *none*|"") echo "Blocking: none" ;;
    *) echo "Blocking: $(awk 'tolower($0) ~ /^\*\*blocking\*\*/ {f=1; next} /^\*\*/ {f=0} f && /^[-*0-9]/ {c++} END {print c+0}' "$1") item(s)" ;;
  esac
}

review_pr() {
  local n="$1" author="$2" branch="$3"
  local dir="$WORK_DIR/pr-$n"
  local out="$REVIEWS_DIR/pr-$n.md"
  local final="$REVIEWS_DIR/pr-$n.final.md"
  local logf="$LOGS_DIR/pr-$n.log"
  local rc comment_url prompt notes summary

  log "PR #$n by @$author ($branch) — starting review under $SKILL_NAME v$SKILL_VERSION"
  slack_post "Reviewing PR #$n by @$author ($branch)."
  : >"$logf"
  rm -f "$out" "$final"

  if [ ! -d "$dir/.git" ]; then
    if ! gh repo clone "$REPO" "$dir" >>"$logf" 2>&1; then
      log "PR #$n: clone failed (see $logf)"
      return 1
    fi
  fi
  if ! (cd "$dir" && gh pr checkout "$n" >>"$logf" 2>&1); then
    log "PR #$n: checkout failed (see $logf)"
    return 1
  fi
  log "PR #$n: checked out in $dir"

  prompt="$(sed "s/{{PR}}/$n/g; s|{{OUT}}|$out|g" "$REVIEWER_HOME/review-prompt.md")"
  log "PR #$n: running claude -p (output: $logf)"
  (cd "$dir" && claude --dangerously-skip-permissions -p "$prompt") >>"$logf" 2>&1
  rc=$?
  log "PR #$n: claude exit code $rc"

  if [ ! -s "$out" ]; then
    log "PR #$n: no review written to $out; not posting"
    return 1
  fi

  notes="$(grep -i -A3 'environment notes' "$out" | tr '\n' ' ' | cut -c1-300)"
  [ -n "$notes" ] && log "PR #$n: review says: $notes"

  { cat "$out"; printf '\n'; footer "$n" "$author"; } >"$final"
  if ! comment_url="$(gh pr comment "$n" --repo "$REPO" --body-file "$final" 2>>"$logf")"; then
    log "PR #$n: gh pr comment failed (see $logf)"
    return 1
  fi
  log "PR #$n: comment posted $comment_url"
  echo "$n" >>"$STATE_FILE"

  summary="$(section_first_line "$out" "Summary" | cut -c1-300)"
  notes="$(section_first_line "$out" "Environment notes" | cut -c1-200)"
  slack_post "Review of PR #$n posted: $comment_url"$'\n'"${summary:-No summary.}"$'\n'"$(blocking_summary "$out")${notes:+$'\n'Environment notes: $notes}"
}

poll_slack() {
  local lines cursor ts user text n
  cursor="$(cat "$SLACK_CURSOR")"
  if ! lines="$(bash "$BIN_DIR/slack-read.sh" --since "$cursor" 2>&1)"; then
    log "slack read failed: $lines"
    return
  fi
  [ -z "$lines" ] && return
  while IFS=$'\t' read -r ts user text; do
    [ -n "$ts" ] && echo "$ts" >"$SLACK_CURSOR"
    case "$(printf '%s' "$text" | tr '[:upper:]' '[:lower:]' | tr -s ' ')" in
      reviewer:\ re-review\ *)
        n="$(printf '%s' "$text" | sed -E 's/.*re-review[[:space:]]+#?([0-9]+).*/\1/')"
        if grep -qxF "$n" "$STATE_FILE"; then
          sed -i "/^$n\$/d" "$STATE_FILE"
          unset "attempts[$n]"
          log "Slack: re-review of PR #$n requested by $user"
          slack_post "Re-reviewing PR #$n on request from <@$user>. It will be picked up on the next poll if it is still open."
        else
          log "Slack: re-review of PR #$n requested by $user, but it is not in the handled list; ignoring"
        fi
        ;;
      reviewer:\ status*)
        log "Slack: status requested by $user"
        slack_post "Status: polling $REPO every ${POLL_SECONDS}s as @$BOT_LOGIN; $(wc -l <"$STATE_FILE" | tr -d ' ') PR(s) reviewed; up $(( ($(date +%s) - STARTED_AT) / 60 )) min."
        ;;
    esac
  done <<<"$lines"
}

poll_once() {
  local prs n author branch url
  if ! prs="$(gh pr list --repo "$REPO" --state open \
      --json number,author,headRefName,url \
      --jq '.[] | [.number, .author.login, .headRefName, .url] | @tsv' 2>&1)"; then
    log "gh pr list failed: $prs"
    return
  fi
  [ -z "$prs" ] && return
  while IFS=$'\t' read -r n author branch url; do
    grep -qxF "$n" "$STATE_FILE" && continue
    if [ "${attempts[$n]:-0}" -ge "$MAX_ATTEMPTS" ]; then
      continue
    fi
    attempts[$n]=$(( ${attempts[$n]:-0} + 1 ))
    if ! review_pr "$n" "$author" "$branch" && [ "${attempts[$n]}" -ge "$MAX_ATTEMPTS" ]; then
      log "PR #$n: giving up after $MAX_ATTEMPTS attempts (restart the sandbox or clear the counter to retry)"
      slack_post "Gave up on PR #$n after $MAX_ATTEMPTS attempts; see the reviewer log."
    fi
  done <<<"$prs"
}

identity="$(gh api user --jq .login 2>/dev/null || echo unknown)"
BOT_LOGIN="${BOT_LOGIN:-$identity}"
log "authenticated to GitHub as $identity (footer identity: $BOT_LOGIN, locked down: $REVIEWER_LOCKED_DOWN)"
log "polling $REPO every ${POLL_SECONDS}s"
if [ -n "${SLACK_CHANNEL_ID:-}" ]; then
  log "Slack: posting to channel $SLACK_CHANNEL_ID and reading commands from it"
else
  log "Slack: not configured (SLACK_BOT_TOKEN / SLACK_CHANNEL_ID unset)"
fi
slack_post "Reviewer online. Polling $REPO every ${POLL_SECONDS}s as @$identity. Say \`reviewer: re-review <N>\` or \`reviewer: status\`."

while true; do
  poll_slack
  poll_once
  sleep "$POLL_SECONDS"
done
