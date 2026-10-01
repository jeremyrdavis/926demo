#!/usr/bin/env bash
# Entrypoint for the reviewer sandbox: poll GitHub for open PRs, review each
# new one with Claude Code under the code-review skill, and post the review
# with a traceability footer. The agent only writes a file; this script posts.
#
# set -u, not set -e: one failed review must not kill the loop.
set -u

REPO="${REPO:-}"
POLL_SECONDS="${POLL_SECONDS:-30}"
REVIEWER_HOME="${REVIEWER_HOME:-/home/agent}"

SKILL_NAME="code-review"
SKILL_VERSION="1.0.0"
BOT_LOGIN="${BOT_LOGIN:-acme-reviewer-bot}"
SANDBOX_LABEL="${SANDBOX_NAME:-reviewer}"
MODEL_LABEL="${ANTHROPIC_MODEL:-Claude Code default}"
SBX_VERSION="${SBX_VERSION:-unknown}"
MAX_ATTEMPTS=3

STATE_DIR="$REVIEWER_HOME/state"
STATE_FILE="$STATE_DIR/handled.txt"
REVIEWS_DIR="$REVIEWER_HOME/reviews"
LOGS_DIR="$REVIEWER_HOME/logs"
WORK_DIR="$REVIEWER_HOME/workspace"

log() {
  printf '%s [reviewer] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

if [ -z "$REPO" ]; then
  log "REPO is not set (launch with -e REPO=<owner>/<repo>)" >&2
  exit 2
fi

mkdir -p "$STATE_DIR" "$REVIEWS_DIR" "$LOGS_DIR" "$WORK_DIR"
touch "$STATE_FILE"

declare -A attempts

footer() {
  local n="$1" author="$2"
  printf -- '---\n'
  printf '_Reviewed by `%s` · sandbox `%s` · skill `%s` v%s · model %s · triggered by PR #%s opened by @%s · %s · Docker Sandboxes %s_\n' \
    "$BOT_LOGIN" "$SANDBOX_LABEL" "$SKILL_NAME" "$SKILL_VERSION" "$MODEL_LABEL" \
    "$n" "$author" "$(date -u +'%Y-%m-%d %H:%M:%SZ')" "$SBX_VERSION"
  printf '_This agent can read code and comment. It cannot push, approve, or merge._\n'
}

review_pr() {
  local n="$1" author="$2" branch="$3"
  local dir="$WORK_DIR/pr-$n"
  local out="$REVIEWS_DIR/pr-$n.md"
  local final="$REVIEWS_DIR/pr-$n.final.md"
  local logf="$LOGS_DIR/pr-$n.log"
  local rc comment_url prompt notes

  log "PR #$n by @$author ($branch) — starting review under $SKILL_NAME v$SKILL_VERSION"
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
    fi
  done <<<"$prs"
}

identity="$(gh api user --jq .login 2>/dev/null || echo unknown)"
log "authenticated to GitHub as $identity"
log "polling $REPO every ${POLL_SECONDS}s"

while true; do
  poll_once
  sleep "$POLL_SECONDS"
done
