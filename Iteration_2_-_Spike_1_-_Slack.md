# Iteration 2, Spike 1 — Slack messaging for the developer and reviewer

Scope: add sending and receiving of Slack messages to the two existing sandboxes. Nothing else from `Iteration_2_-_Requirements.md` is in this spike. Starting point is tag `step-01`; the end state is tag `step-02`.

## 1. Goal

`#agentic-team` in `mobyai.slack.com` becomes the third surface, after the PR comment and `sbx policy log`, on which the audience can see the two agents act. Every post carries the same attribution the PR footer carries. Each agent also reads from the channel, so a human can address an agent in Slack and see it react.

What the audience sees: the reviewer announces itself when it starts polling, announces each PR it picks up, posts its verdict with a link to the full comment, and reacts when a human types `reviewer: re-review 7`. The developer announces the spec it starts on and posts the PR link when the PR exists; when launched without a task, it takes the task from the latest `developer:` message in the channel.

What we say honestly: the Slack token is an environment variable inside the sandbox, unlike the GitHub token, which is a sentinel swapped by the proxy. `sbx` injects credentials only for its built-in services, and Slack is not one of them today. The token is scoped to one bot in one channel and is rotated after the demo.

## 2. Decisions (defaults chosen; override if wrong)

| Decision | Default | Why |
| :---- | :---- | :---- |
| Slack apps | **Two apps**, `Developer Agent` and `Reviewer Agent`, one bot token each | Distinct names and avatars in the channel without any display-name spoofing; one token per sandbox, which matches how GitHub secrets are scoped. Fallback: one app with `chat:write.customize` and a `username` per post. |
| Token delivery | `--env-file` on `sbx create` (developer) and on `sbx create` + verified inheritance by `sbx exec` (reviewer) | Keeps the token out of shell history and `ps`. `sbx secret set` has no `slack` service. If `sbx exec` does not inherit create-time env, fall back to `sbx exec -e SLACK_BOT_TOKEN=... -e SLACK_CHANNEL_ID=...`. |
| Transport | `curl` against the Slack Web API (`chat.postMessage`, `conversations.history`, `auth.test`), JSON parsed with `python3` | No SDK, no new dependency; the reviewer cannot install anything anyway. |
| Receive mechanism | Polling `conversations.history` on the same cadence as the GitHub poll, cursor kept in `state/slack-cursor` | No public endpoint, no Socket Mode, works behind the sandbox proxy. |
| Who posts for the developer | The agent, via a step in the `implementer` Skill that calls the kit's `slack-post.sh` | Decided 2026-10-02. The script fixes the message format; the model only decides when to call it. |
| Message style | Plain Slack mrkdwn, no emoji, attribution as the last line in italics | Matches the PR footer. |
| Network | Add `slack.com` to the allow list of all four kits | The Web API is served from `https://slack.com/api/…`. Patterns are exact hosts. |

## 3. Architecture

```
Mac
├── Sandbox "developer"  (kit developer-mixin, env: SLACK_BOT_TOKEN=xoxb-dev…, SLACK_CHANNEL_ID=C…)
│     allow: github.com, api.github.com, api.anthropic.com, pypi.org, files.pythonhosted.org, slack.com
│     /home/agent/bin/slack-post.sh, slack-read.sh
│     skill implementer v1.1.0: reads task from Slack if none given; posts start and PR link
│
├── Sandbox "reviewer"   (kit reviewer-mixin, env: SLACK_BOT_TOKEN=xoxb-rev…, SLACK_CHANNEL_ID=C…)
│     allow: github.com, api.github.com, api.anthropic.com, slack.com   deny: pypi.org, files.pythonhosted.org, registry.npmjs.org
│     reviewer-loop.sh: posts online/pickup/verdict/failure; polls Slack for `reviewer:` commands
│
└── Slack #agentic-team (mobyai.slack.com)
      human  →  "developer: implement specs/001-discount-codes.md"   →  developer picks it up
      human  →  "reviewer: re-review 7"                                →  reviewer clears PR 7 from handled.txt
      agents →  posts, each ending with _sandbox · skill vX · model · time_
```

## 4. Component specs

### 4.1 Slack apps

Create in `mobyai.slack.com` from the manifest below, once per agent (change `name` and `display_name`). Bot token scopes: `chat:write` (post), `channels:history` (read the channel), `channels:read` (resolve the channel). Install to the workspace, copy the Bot User OAuth Token (`xoxb-…`), and invite each bot to `#agentic-team` (`/invite @Developer Agent`, `/invite @Reviewer Agent`). The channel ID is at the bottom of the channel's details pane and starts with `C`.

```yaml
display_information:
  name: Reviewer Agent
  description: Code-review agent running in a Docker Sandbox
features:
  bot_user:
    display_name: Reviewer Agent
    always_online: false
oauth_config:
  scopes:
    bot:
      - chat:write
      - channels:history
      - channels:read
settings:
  org_deploy_enabled: false
  socket_mode_enabled: false
  token_rotation_enabled: false
```

Verification: `curl -s -H "Authorization: Bearer $TOKEN" https://slack.com/api/auth.test` returns `"ok":true` and the bot `user`. If the workspace requires admin approval for new apps, request it at install time; nothing else in this spike can start until both tokens exist.

### 4.2 Token storage on the host

`sbx secret set` has no `slack` service, so the token cannot use the proxy-injection path. Two acceptable host stores, both never in the repo:

- **Keychain (preferred):** `security add-generic-password -a reviewer -s agentic-team-slack -w` (prompts for the token; repeat with `-a developer`), then resolve inline at create time: `-e SLACK_BOT_TOKEN="$(security find-generic-password -s agentic-team-slack -a reviewer -w)" -e SLACK_CHANNEL_ID=C…`. No plaintext file; shell history records the command, not the value.
- **Env file:** `~/.config/agentic-team/{developer,reviewer}.env`, mode 600, lines `SLACK_BOT_TOKEN=xoxb-…` and `SLACK_CHANNEL_ID=C…`, passed with `--env-file` on `sbx create`.

Either way the value is an ordinary environment variable inside the sandbox (demo beat 6). Section 6 verifies that create-time variables are visible to `sbx exec`, which the reviewer loop depends on.

### 4.3 `files/home/bin/slack-post.sh` (identical in all four kits)

```
slack-post.sh [--skill NAME --skill-version V] TEXT...
```

Posts `TEXT` to `$SLACK_CHANNEL_ID` with `chat.postMessage`, appending the attribution line
`_sandbox <SANDBOX_NAME> · skill <NAME> v<V> · model <ANTHROPIC_MODEL or "Claude Code default"> · <UTC time>_`.
Exits 0 only when the API returns `"ok":true`; prints the Slack error otherwise. Missing `SLACK_BOT_TOKEN` or `SLACK_CHANNEL_ID` is a one-line warning and exit 0, so a sandbox launched without Slack still works. `set -u`, `curl --fail-with-body`, text passed with `--data-urlencode` (no shell interpolation into JSON).

### 4.4 `files/home/bin/slack-read.sh` (identical in all four kits)

```
slack-read.sh --since TS            # messages newer than TS, oldest first, as TSV: ts<TAB>user<TAB>text
slack-read.sh --latest-prefix 'developer:'   # text of the newest message starting with the prefix, prefix stripped
```

Calls `conversations.history` with `channel`, `oldest`, `limit=50`, `inclusive=false`; ignores messages whose `bot_id` is set (agents never react to agents, which prevents loops). Same env-var handling as `slack-post.sh`.

### 4.5 `reviewer-loop.sh` changes

- On startup, after the GitHub identity line: `slack-post.sh "Reviewer online. Polling <REPO> every <N>s as @<login>."`
- On pickup: `"Reviewing PR #N by @author (branch)."`
- On verdict: first line of **Summary**, the number of **Blocking** items, the **Environment notes** line if present, and the comment URL.
- On give-up after `MAX_ATTEMPTS`: one failure post.
- Each cycle, before the GitHub poll: `slack-read.sh --since "$(cat state/slack-cursor)"`; for each line whose text matches `^reviewer:\s*re-review\s+#?([0-9]+)` remove that number from `handled.txt`, reset its attempt counter, and post `"Re-reviewing PR #N on request from <user>."`; for `^reviewer:\s*status` post handled count and uptime. Advance the cursor to the newest `ts` seen, even when nothing matched. Unknown commands are ignored silently.
- Slack failures are logged and never abort a review; the PR comment remains the source of truth.

### 4.6 `implementer` Skill v1.1.0 (developer kit)

Adds three steps to the existing six and bumps `version` in the frontmatter:

0. If you were not given a spec path, run `bash ~/bin/slack-read.sh --latest-prefix 'developer:'` and treat its output as your task. If it prints nothing, say so and stop.
1a. Before branching: `bash ~/bin/slack-post.sh --skill implementer --skill-version 1.1.0 "Starting <spec path>."`
5a. After `gh pr create`: `bash ~/bin/slack-post.sh --skill implementer --skill-version 1.1.0 "Opened <PR URL> for <spec path>."`

`agentInstructions` gains one sentence: "Announce starts and PR links in Slack with `bash ~/bin/slack-post.sh`; never post anything else." The PR body is unchanged.

### 4.7 Kit `spec.yaml` changes

All four kits: `slack.com` appended to `permissions.network.allow`. No other changes; files land under `/home/agent/bin/` via `files/home/bin/`. **Kit files lose their executable bit when copied into the sandbox** (observed 2026-10-02: `OCI runtime exec failed: … not executable`), so every caller invokes the helpers as `bash ~/bin/<script>`; the same is already true of `reviewer-loop.sh`.

## 5. Non-goals for this spike

Coordinator, Quarkus app, Codex, identity work, threads or reactions in Slack, Slack as the only trigger (the GitHub poll stays), reading DMs, more than one channel, posting file attachments.

## 6. Build checklist (in order, each with its verification)

**Status 2026-10-02:** every item below was run on the Mac and worked; tagged `step-02`. Facts learned along the way: `sbx secret set` has no `slack` service (token goes in by `--env-file`); create-time `--env-file` variables are visible to `sbx exec`; kit `files/` lose their executable bit, so helpers are invoked with `bash`. The Developer Agent and Reviewer Agent post under their own names.

### Slack

- [x] Two apps created from the 4.1 manifest, installed, both bots invited to `#agentic-team`. Verify: `auth.test` returns `ok` for each token and the `user` names differ.
- [x] Channel ID recorded. Verify: `curl -s -H "Authorization: Bearer $TOKEN" "https://slack.com/api/conversations.history?channel=$CHANNEL_ID&limit=1"` returns `ok` (needs `channels:history` and the bot in the channel).
- [x] `~/.config/agentic-team/{developer,reviewer}.env` written, `chmod 600`.

### Kit files (offline, in this repo)

- [x] `slack-post.sh` and `slack-read.sh` written once and copied into all four `files/home/bin/`; executable; `bash -n` clean. Verify with a stub `curl` on `PATH` that returns `{"ok":true}` and `{"ok":false,"error":"x"}`: exit codes 0 and 1, attribution line present, no-token case warns and exits 0.
- [x] `reviewer-loop.sh` per 4.5 in both reviewer kits; exercised against stub `gh`, `claude` and `curl`: posts on startup/pickup/verdict, `re-review` removes the PR from `handled.txt`, cursor advances, bot-authored messages ignored.
- [x] `implementer/SKILL.md` v1.1.0 in both developer kits; `agentInstructions` updated in both developer `spec.yaml`.
- [x] `slack.com` in all four allow lists; `sbx kit validate` on all four.

### Mac, reviewer

- [x] `sbx rm --force reviewer`; `sbx create --name reviewer --skills=off --kit ./kits/reviewer-mixin --env-file ~/.config/agentic-team/reviewer.env claude`; re-set the scoped GitHub secret (`-t "$(gh auth token --user jeremyrdavis)"`).
- [x] `sbx exec reviewer printenv SLACK_CHANNEL_ID` prints the ID. If empty, create-time env does not reach `exec`; switch the launch to `sbx exec -e SLACK_BOT_TOKEN=… -e SLACK_CHANNEL_ID=…` and record it.
- [x] `sbx policy check network --sandbox reviewer slack.com` → Allowed; `pypi.org` still Denied.
- [x] Start the loop; within one cycle the "Reviewer online" post appears in `#agentic-team` with the attribution line.
- [x] Type `reviewer: status` in Slack; the reply arrives within one poll interval. Type `reviewer: re-review 999`; log shows it was ignored (no such handled PR) and nothing crashes.

### Mac, developer

- [x] `sbx create --name developer --skills=off --kit ./kits/developer-mixin --env-file ~/.config/agentic-team/developer.env claude ~/src/sbx-demo-app`; scoped GitHub secret; `sbx exec developer gh auth status`.
- [x] `sbx exec developer bash /home/agent/bin/slack-post.sh --skill test --skill-version 0 "developer sandbox smoke test"` posts.
- [x] Type `developer: implement specs/001-discount-codes.md using the implementer skill` in Slack, then `sbx run --name developer -- "Take your task from Slack."` The "Starting specs/001…" post appears, then the PR, then the "Opened <URL>" post.

### End to end

- [x] Reviewer posts pickup and verdict for that PR; verdict post links the comment; PR comment unchanged from iteration 1.
- [x] `reviewer: re-review <N>` in Slack produces a second review and a second comment within two poll intervals.
- [x] Reset: close PR, delete branch, `sbx rm --force developer` (and its secret dies with it), clear the PR from `handled.txt` or recreate the reviewer. Slack history stays; that is fine.
- [x] Clean run twice, then tag `step-02`.

## 7. Demo beats added to the iteration 1 runbook

| Beat | Show | Say |
| :---- | :---- | :---- |
| 0 (pre-staged) | `#agentic-team` on screen with the "Reviewer online" post | "The reviewer has been on shift since before we started. It told the team so." |
| 3' | Type the `developer:` task in Slack, then launch the developer with "Take your task from Slack." | "The handoff from me to the team is a Slack message. The agent reads it from the same place a human teammate would." |
| 4' | Reviewer posts pickup, then verdict, in Slack; click through to the PR comment | "Same verdict, three surfaces: Slack for the team, GitHub for the record, `sbx policy log` for what it was not allowed to do." |
| 5' | Type `reviewer: re-review N`; watch the log and the second comment | "Receiving, not just sending. The loop treats the channel as an inbox." |
| 6 (concession) | `sbx exec reviewer printenv SLACK_BOT_TOKEN` next to `printenv GH_TOKEN` | "One is a sentinel the proxy swaps; the other is a real token, because Slack isn't a service the runtime knows yet. That's the gap I'm asking Docker to close." |

## 8. Scope-cut order

1. Drop the developer's Slack *read* (task given on the command line as in iteration 1); keep its posts.
2. Drop the reviewer's `re-review` command; keep `status` or drop reads entirely.
3. Drop the developer's posts (model-dependent); keep the reviewer's (script-driven).
4. One Slack app instead of two.

## 9. Reference — syntax used in this spike

Slack Web API (bot token in `Authorization: Bearer xoxb-…`):

```
POST https://slack.com/api/chat.postMessage        form: channel, text            scope chat:write
GET  https://slack.com/api/conversations.history   query: channel, oldest, limit, inclusive   scope channels:history
GET  https://slack.com/api/auth.test                                                any bot token
```

Responses are JSON with `ok` true/false and `error` on failure (`not_in_channel`, `channel_not_found`, `missing_scope`, `invalid_auth`). `conversations.history` returns newest first; `ts` is a string like `1759450000.123456` and is the cursor. Messages posted by apps carry `bot_id`.

`sbx` (from spec section 9 and `sbx secret set --help`, 2026-10-02): `--env-file` and `-e/--env` on `run`/`create`; `-e K=V` on `exec`; service secrets limited to `anthropic, bedrock, copilot, cursor, devin, droid, github, google, groq, mistral, nebius, openai, openrouter, xai` — no `slack`.

## 10. Known risks

- **App install approval** in `mobyai.slack.com` may need a workspace admin; ask on day one. Fallback for sending only: an incoming webhook, which still requires an approved app.
- **Token visible in the sandbox.** Stated openly in beat 6. Rotate both tokens after Tuesday.
- **The developer agent may skip a Slack step.** The Skill makes it explicit, and the end-to-end item checks it; if it is flaky, cut per section 8 item 3.
- **`sbx exec` env inheritance** is unverified; the checklist resolves it on the first reviewer launch.
- **Agent-to-agent loops.** Prevented by ignoring `bot_id` messages; keep that filter.
- **Rate limits.** `conversations.history` at one call per 30 s per bot is far below Slack's limits.
