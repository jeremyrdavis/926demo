# Iteration 1 — Developer Sandbox \+ Reviewer Sandbox

Spec and build checklist for the Acme Games "agent acting on behalf of a user" demo. Written to be handed to Claude Code as-is. Target: runnable live on **Wednesday, September 30, 2026**.

---

## 0\. Kickoff prompt for Claude Code

> Read `Iteration 1 - Spec and Checklist.md` in full. Build everything in section 4 in the order given in section 6, checking off each item and running its verification step before moving on. Resolve the open decisions in section 2 using the stated defaults unless I say otherwise. Every `sbx` command you run must match the syntax in section 9 — do not invent flags. If a documented command behaves differently than described, stop, show me the actual output, and propose the smallest workaround. When section 6 is complete, run the full runbook in section 7 end to end and record a screen capture as the fallback.

---

## 1\. Goal and demo narrative

Two Docker Sandboxes on one Mac, running the same agent (Claude Code) under two different kits with visibly different blast radii.

1. **Developer sandbox** — runs as Jeremy, with a broad network policy and Jeremy's own GitHub token. Given a short feature spec, it implements the change on a branch, pushes, and opens a PR.  
2. **Reviewer sandbox** — runs as a distinct GitHub identity (`acme-reviewer-bot`) with a token that can read code and write PR comments and nothing else. It is a long-running sandbox that polls GitHub every 30 seconds, checks out each new PR into its own workspace, runs a code review under a versioned review Skill, and posts a comment carrying a traceability footer.  
3. **The denial beat** — the review Skill instructs the agent to install dependencies and run the tests. The reviewer's network policy blocks the package registry. The agent reports the block and falls back to static review. The attempt shows up as a DENY in `sbx policy log` (and in the audit log if governance is active). The task still completes.

What the audience must see is Docker machinery, not Claude output: two kit files side by side, the policy check before anything runs, the denial in the log, the review comment authored by a non-human identity, and the footer that answers "who did this, on whose behalf, under which instructions."

What we say honestly: in this iteration both sandboxes run under Jeremy's **Docker** identity. The reviewer's **GitHub** identity is distinct and its permissions are a strict subset. Distinct Docker agent identity is the roadmap item.

---

## 2\. Open decisions (defaults chosen; override if wrong)

| Decision | Default | Why |
| :---- | :---- | :---- |
| Kit schema | **v2** (`spec.yaml`, `extends: claude`) | Lighter than v3 (no Dockerfile, no buildx push), skills placement is documented, works from a local directory. v3 is the current direction and requires sbx ≥ 0.45; migrate in iteration 2\. Do not mix v2 and v3 in one sandbox. |
| Claude Code auth | **`ANTHROPIC_API_KEY`** via `sbx secret set anthropic` | Docs: proxy-managed OAuth is not supported for third-party kits, including kits that extend a built-in agent. |
| Reviewer GitHub identity | **Machine user** `acme-reviewer-bot` with a fine-grained PAT | Fastest tonight. Upgrade to a GitHub App with one-hour installation tokens in iteration 2 (that becomes the "delegation with expiry" story). |
| Demo repo | **New public or private repo `sbx-demo-app`**, small Python service with pytest | Python gives a natural denial (pip against PyPI). Planted review targets described in 4.1. |
| Reviewer poll loop | **Inside the sandbox**, as the kit entrypoint | Shows a long-running sandbox and streams the log in a terminal. Fallback: host-side loop using `sbx exec`. |
| Who posts the comment | **The loop script**, not the agent | Agent writes `review.md`; script appends the footer and posts with `gh pr comment --body-file`. Deterministic footer, boring agent output. |
| Local network preset | **`deny-all`** on the demo machine | Makes kits the only source of allow rules, so the two kits fully define the two blast radii. See 4.6 for what changes if org governance is active. |
| Shared skills store | **`--skills=off`** on both sandboxes | Keeps the shared store from mounting over the kit-provided skill. |

---

## 3\. Architecture

```
Mac (Jeremy, signed in to Docker; sbx policy preset = deny-all)
│
├── Sandbox "developer"  ← kit ./kits/developer  (v2, extends: claude)
│     workspace: ~/src/sbx-demo-app (bind mount, direct mode)
│     network allow: github.com, api.github.com, api.anthropic.com, pypi.org, files.pythonhosted.org
│     credentials: github = Jeremy's token (sandbox-scoped), anthropic = API key (global)
│     skill: implementer   (spec-driven, commit, push, gh pr create)
│
├── Sandbox "reviewer"    ← kit ./kits/reviewer   (v2, extends: claude, custom entrypoint)
│     workspace: none on host (mountless; clones PR into /home/agent/workspace/pr-<N>)
│     network allow: github.com, api.github.com, api.anthropic.com
│     network deny:  pypi.org, files.pythonhosted.org, registry.npmjs.org
│     credentials: github = acme-reviewer-bot fine-grained PAT (sandbox-scoped), anthropic = API key (global)
│     skill: code-review v1.0.0
│     entrypoint: /home/agent/reviewer-loop.sh  (poll every 30s)
│
└── GitHub repo <owner>/sbx-demo-app
      PR opened by Jeremy (via developer sandbox) → comment by acme-reviewer-bot (via reviewer sandbox)
```

Traceability surfaces, in order of what the audience sees:

1. PR comment footer (human-readable, on GitHub).  
2. `sbx policy log reviewer --json` (allow/deny decisions per host, with sandbox attribution).  
3. Reviewer loop log (which PR, which Skill version, exit codes).  
4. Audit records at `~/Library/Logs/com.docker.sandboxes/sandboxes/auditkit/*.jsonl` — **only** if Jeremy's Docker org has AI Governance with enforced centralized policy. Check first; do not promise it.

---

## 4\. Component specs

### 4.1 Demo repo `sbx-demo-app`

Small Python service, \~150 lines, with pytest tests. Contents on `main`:

- `app/` — a tiny HTTP-less module (e.g., `inventory.py` with `add_item`, `remove_item`, `total_value`) plus `__init__.py`.  
- `tests/test_inventory.py` — passing tests.  
- `requirements.txt` — `pytest` plus one non-stdlib runtime dependency (e.g., `pydantic`) so `pip install` is unavoidable for a "run the tests" step.  
- `README.md` — one paragraph.  
- `specs/001-discount-codes.md` — the feature spec the developer sandbox will implement (see below).  
- `CLAUDE.md` — project instructions: run tests with `pytest`, commit style, branch naming `feat/<spec-id>`.

Feature spec `specs/001-discount-codes.md`: add `apply_discount(code: str, total: float) -> float` supporting percentage codes (`SAVE10`, `SAVE25`) and a fixed-amount code (`FLAT5`); invalid codes raise `ValueError`; never return negative totals. Include acceptance criteria as a bullet list.

Planted review targets (so the review has something to find regardless of how the implementer behaves): the developer Skill (4.2) instructs the implementer to be fast and minimal and **not** to add tests. This reliably yields at least: no tests for the new function, no handling of the negative-total rule, or a hard-coded code table. Do not plant anything the audience would read as fake. If the implementer happens to write a perfect PR, the reviewer still posts (a "no blocking issues" review is fine) and the denial beat still happens.

Branch protection on `main`: require one approving review. This makes "reviewer cannot merge" enforceable at GitHub, not just at the token.

### 4.2 Developer kit `./kits/developer`

```
kits/developer/
├── spec.yaml
└── files/
    └── home/
        └── .claude/
            └── skills/
                └── implementer/
                    └── SKILL.md
```

`spec.yaml` (v2):

```
schemaVersion: "2"
kind: sandbox
name: acme-developer
displayName: Developer (implementer)
description: Claude Code with push access, implements specs and opens PRs

extends: claude

agentInstructions:
  filename: CLAUDE.md
  content: |
    You are the implementer on this team. Work only from files under specs/.
    Branch from main as feat/<spec-id>. Commit with a conventional message.
    Push and open a PR with `gh pr create` whose body links the spec.
    Be fast and minimal. Do not add tests; the reviewer owns test coverage.
    Stop after the PR URL is printed.

permissions:
  network:
    allow:
      - github.com
      - api.github.com
      - api.anthropic.com
      - pypi.org
      - files.pythonhosted.org
```

Notes for the builder:

- Verify whether `extends: claude` inherits the built-in `anthropic` and `github` credential declarations. If it does not, add a `credentials:` block using the built-in service names (`anthropic` → `ANTHROPIC_API_KEY` on `api.anthropic.com`; `github` → `GH_TOKEN`/`GITHUB_TOKEN` on `api.github.com`, `github.com`).  
- Third-party kits need a credential binding in `~/.config/sbx/credentials.yaml`. Run the kit interactively once to create bindings, or write the file directly (format in section 9).  
- `SKILL.md` for `implementer`: frontmatter `name: implementer`, `description: Implement a spec from specs/ and open a PR`. Body: the steps above plus "print the PR URL as the last line."

Launch (direct mode, bind-mounted so the audience can see files change on the host):

```
$ sbx run --name developer --skills=off ./kits/developer ~/src/sbx-demo-app -- "Implement specs/001-discount-codes.md using the implementer skill."
```

### 4.3 Reviewer kit `./kits/reviewer`

```
kits/reviewer/
├── spec.yaml
└── files/
    └── home/
        ├── reviewer-loop.sh
        ├── review-prompt.md
        └── .claude/
            └── skills/
                └── code-review/
                    └── SKILL.md
```

`spec.yaml` (v2):

```
schemaVersion: "2"
kind: sandbox
name: acme-reviewer
displayName: Reviewer (locked down)
description: Long-running code reviewer; read-only code, comment-only PR access

extends: claude

sandbox:
  entrypoint: [bash, /home/agent/reviewer-loop.sh]

agentInstructions:
  filename: CLAUDE.md
  content: |
    You are the reviewer on this team. You never modify code, never push,
    never approve or merge. You read the PR diff, run the tests if you can,
    and write your findings to the path given in the prompt. Use the
    code-review skill. If a command is blocked by network policy, say so
    in one line under "Environment notes" and continue with static review.

permissions:
  network:
    allow:
      - github.com
      - api.github.com
      - api.anthropic.com
    deny:
      - pypi.org
      - files.pythonhosted.org
      - registry.npmjs.org
```

Deny rules are listed even though `deny-all` is the local preset. Reason: under org governance, kit **allow** rules are inactive but kit **deny** rules still apply, so the lockdown survives either regime.

Launch (mountless; the reviewer never sees the host filesystem):

```
$ sbx run --name reviewer --skills=off -e REPO=<owner>/sbx-demo-app -e POLL_SECONDS=30 ./kits/reviewer
```

### 4.4 `reviewer-loop.sh`

Requirements:

- Runs as the sandbox entrypoint; must tolerate restart (state file of handled PR numbers at `/home/agent/state/handled.txt`).  
- Every `$POLL_SECONDS`: `gh pr list --repo "$REPO" --state open --json number,author,headRefName,url`. For each PR not in the state file:  
  1. Log `[reviewer] PR #N by @author (branch) — starting review under code-review v1.0.0`.  
  2. `gh repo clone "$REPO" /home/agent/workspace/pr-N` (or fetch if exists), `gh pr checkout N`.  
  3. `cd` there and run `claude --dangerously-skip-permissions -p "$(sed "s/{{PR}}/N/g; s|{{OUT}}|/home/agent/reviews/pr-N.md|g" /home/agent/review-prompt.md)"`, capturing stdout to `/home/agent/logs/pr-N.log` and the exit code.  
  4. If `/home/agent/reviews/pr-N.md` exists, append the footer (4.5) and `gh pr comment N --repo "$REPO" --body-file /home/agent/reviews/pr-N.md`. Log the comment URL.  
  5. Append N to the state file only after the comment succeeds. Log the exit code either way.  
- Log to stdout with timestamps and a `[reviewer]` prefix; the audience reads this terminal.  
- `set -u`, not `set -e` — one failed review must not kill the loop.

`review-prompt.md`: "Review PR {{PR}} in the current checkout using the code-review skill. Write the review as GitHub-flavored Markdown to {{OUT}} and nothing else. Do not post it yourself."

### 4.5 Traceability footer

Appended by the loop script, exactly:

```
---
_Reviewed by `acme-reviewer-bot` · sandbox `reviewer` · skill `code-review` v1.0.0 · model <from claude output or env> · triggered by PR #N opened by @<author> · <UTC timestamp> · Docker Sandboxes <sbx version>_
_This agent can read code and comment. It cannot push, approve, or merge._
```

The last line is the "on behalf of" statement in plain language. Keep it.

### 4.6 `code-review` Skill (v1.0.0)

`SKILL.md` frontmatter: `name: code-review`, `description: Review a pull request for correctness, tests, and spec compliance`, `version: 1.0.0`.

Body, in order:

1. Read the linked spec under `specs/` and the PR diff (`gh pr diff N`).  
2. Attempt `pip install -r requirements.txt && pytest -q`. If blocked, record one line under **Environment notes** and continue. (This is the denial beat; do not remove it.)  
3. Check: acceptance criteria met; tests exist for new behavior; error handling matches the spec; no secrets or hard-coded config.  
4. Output format: **Summary** (2 sentences), **Blocking** (list or "none"), **Suggestions** (list), **Environment notes**. Under 300 words. No preamble.

### 4.7 Credentials and identities

| Sandbox | Service | Source | Scope |
| :---- | :---- | :---- | :---- |
| developer | anthropic | `sbx secret set anthropic` (global) | API key |
| developer | github | `sbx secret set github --sandbox developer --command 'gh auth token'` | Jeremy's token via host `gh` |
| reviewer | anthropic | same global secret | API key |
| reviewer | github | `sbx secret set github --sandbox reviewer -t <FINE_GRAINED_PAT>` | `acme-reviewer-bot`, repo `sbx-demo-app` only: Contents **read**, Pull requests **read & write**, Metadata read |

Do **not** set a global `github` secret. If the reviewer's sandbox-scoped secret failed to apply, a global one would silently give the reviewer Jeremy's full token. Verify with `sbx secret ls`.

If `--sandbox <name>` is rejected before the sandbox exists, use `sbx create --name <name> ...` first, then set the secret, then `sbx run --name <name>`.

Optional hardening (only if time permits): `sbx policy deny network --sandbox reviewer github.com --method POST --path '/**/git-receive-pack'` blocks HTTPS push at the proxy in addition to the token scope.

---

## 5\. Non-goals for iteration 1

No Slack. No coordinator. No Hermes. No GitHub App. No cloud sandboxes (`--cloud`). No org policy authored in Docker Home unless it already exists. No CI runner. Do not start any of these until section 7 runs clean twice.

---

## 6\. Build checklist (in order, each with its verification)

### Environment

- [ ] `sbx version` — record it. Need ≥ 0.42 (mountless create). Note `-e/--env` needs ≥ 0.39, `--deny-network` ≥ 0.38.  
      - Verify: version printed and recorded at the top of the runbook notes.  
- [ ] `sbx login` — signed in as Jeremy.  
      - Verify: `sbx ls` succeeds.  
- [ ] `sbx policy ls` — check whether the output says `Governance: Managed by <org>`.  
      - If **not governed**: `sbx policy init deny-all`. Verify: `sbx policy check network pypi.org` → Denied.  
      - If **governed**: do not run `init`. Kit allow rules are inactive; the developer's reach is whatever the org allows. The reviewer lockdown still works via kit deny rules. Confirm `sbx policy check network --sandbox reviewer pypi.org` → Denied once the reviewer exists. Note that org policy edits take up to 5 minutes to land.  
- [ ] `echo "$ANTHROPIC_API_KEY" | sbx secret set anthropic`  
      - Verify: `sbx secret ls` shows `(global) service anthropic`.  
- [ ] Check for audit logs: `ls ~/Library/Logs/com.docker.sandboxes/sandboxes/auditkit/`. Record whether `.jsonl` files exist. If none, the audit surface for the demo is `sbx policy log`.

### GitHub

- [ ] Create repo `<owner>/sbx-demo-app` with the contents in 4.1. Push `main`. Tests pass locally.  
      - Verify: `pytest -q` green on the host.  
- [ ] Branch protection on `main`: require 1 approving review.  
- [ ] Create machine user `acme-reviewer-bot`; add as collaborator with **Read** (Triage is not needed; comments only need PR write via the token). Accept the invite.  
- [ ] Fine-grained PAT on `acme-reviewer-bot`: resource owner \= repo owner, repo \= `sbx-demo-app` only, permissions Contents read, Pull requests read/write, Metadata read. Expiry 7 days. Store it only in the sbx secret store.  
      - Verify from the host: `GH_TOKEN=<pat> gh api repos/<owner>/sbx-demo-app/pulls` works; `GH_TOKEN=<pat> gh api -X PUT repos/<owner>/sbx-demo-app/contents/x` → 403\.

### Kits

- [ ] Write `kits/developer/` per 4.2. `sbx kit validate ./kits/developer`.  
- [ ] Write `kits/reviewer/` per 4.3–4.6, including `reviewer-loop.sh` (executable), `review-prompt.md`, `SKILL.md`. `sbx kit validate ./kits/reviewer`.  
- [ ] First interactive run of each kit to create credential bindings, or write `~/.config/sbx/credentials.yaml` directly (section 9).  
      - Verify: `cat ~/.config/sbx/credentials.yaml` shows `anthropic` and `github` bindings.  
- [ ] `sbx secret set github --sandbox developer --command 'gh auth token'`  
- [ ] `sbx secret set github --sandbox reviewer -t <PAT>`  
      - Verify: `sbx secret ls` shows two sandbox-scoped `github` entries and **no** global `github`.

### Reviewer sandbox

- [ ] `sbx run --name reviewer --skills=off -e REPO=<owner>/sbx-demo-app -e POLL_SECONDS=30 ./kits/reviewer`  
      - Verify: loop log prints `[reviewer] polling <repo> every 30s` and no errors for two cycles.  
- [ ] `sbx policy ls reviewer --wide` — allow list is exactly github.com, api.github.com, api.anthropic.com (plus anything the built-in claude kit adds); deny list includes pypi.org.  
- [ ] `sbx policy check network --sandbox reviewer pypi.org` → Denied. `sbx policy check network --sandbox reviewer api.github.com` → Allowed.  
- [ ] In a second terminal: `sbx exec reviewer gh auth status` → shows `acme-reviewer-bot`, not Jeremy.  
- [ ] `sbx exec reviewer -w /home/agent/workspace sh -c 'gh repo clone <owner>/sbx-demo-app t && cd t && git push origin HEAD:refs/heads/probe'` → fails with 403\. Clean up the `t` directory.  
- [ ] `sbx exec reviewer pip download pydantic` → connection refused/blocked. `sbx policy log reviewer` shows a DENY for pypi.org.

### Developer sandbox

- [ ] Clone the repo to `~/src/sbx-demo-app` on the host, on `main`.  
- [ ] `sbx run --name developer --skills=off ./kits/developer ~/src/sbx-demo-app -- "Implement specs/001-discount-codes.md using the implementer skill."`  
      - Verify: PR appears on GitHub authored by Jeremy, branch `feat/001-discount-codes`, body links the spec.  
- [ ] `sbx exec developer gh auth status` → Jeremy.

### End to end

- [ ] Within 30–60 seconds of the PR opening, the reviewer log shows the PR picked up, the clone, the `claude -p` run, the pip block noted, and `gh pr comment` succeeding with a URL.  
- [ ] On GitHub: comment authored by `acme-reviewer-bot`, with the footer from 4.5, with an **Environment notes** line mentioning the blocked install.  
- [ ] `sbx policy log reviewer --json | jq 'select(.decision=="deny")'` (or equivalent) shows the pypi DENY timestamped inside the review window.  
- [ ] If audit `.jsonl` exists: `grep -l '"resource_id": "pypi.org' ~/Library/Logs/com.docker.sandboxes/sandboxes/auditkit/*.jsonl` finds the record with `"username"` \= Jeremy and `"agent"` \= claude.  
- [ ] Reset for a second run: close the PR, delete the branch, `sbx rm --force developer`, remove the PR number from the reviewer's state file (or `sbx rm --force reviewer` and relaunch). Run the whole thing again clean.  
- [ ] Record a full clean run (screen capture, both terminals and the browser) as the fallback.

---

## 7\. Demo runbook (target 8 minutes)

Pre-staged before the call: reviewer sandbox already running and polling; host repo on `main`; a browser tab on the repo's Pulls page; a second tab on the reviewer kit `spec.yaml`; terminals at large font.

| Beat | Time | Show | Say |
| :---- | :---- | :---- | :---- |
| 1 | 0:00–1:00 | Both `spec.yaml` files side by side | "Two kits, one agent. Same Claude, different blast radius. The reviewer cannot reach a package registry and holds a token that can only read code and comment. Nothing about the prompt makes it safe; the kit does." |
| 2 | 1:00–1:45 | `sbx policy check network --sandbox reviewer pypi.org` → Denied; `sbx exec reviewer gh auth status` → bot | "Before anything runs, we can ask the runtime what this sandbox may do and who it is on GitHub." |
| 3 | 1:45–4:00 | Launch the developer sandbox with the one-line task. Watch the PR appear. | Keep narration on the sandbox, not the code: bind-mounted workspace, Jeremy's token injected at the boundary, agent never sees the raw token. |
| 4 | 4:00–6:00 | Reviewer terminal: PR picked up, clone, pip blocked, review posted | "This is the beat that matters. The Skill told it to run the tests. Policy said no. It said so and kept going. That attempt is now a record." |
| 5 | 6:00–7:00 | GitHub: the comment, then the footer. `sbx policy log reviewer` in the terminal. | "Who did this, under which instructions, triggered by whom, and what it was not allowed to do. Two surfaces, same answer." |
| 6 | 7:00–8:00 | The concession | "Both sandboxes ran under my Docker identity today. The reviewer's GitHub identity is distinct and strictly narrower. A distinct Docker agent principal is the roadmap item I'm getting dates on. Iteration 2 adds a coordinator and per-request, expiring tokens — that's the delegation chain." |

If anything stalls for more than 20 seconds, switch to the recording and narrate over it. Do not debug live.

---

## 8\. Scope-cut order (if running out of time tonight)

1. Drop the branch protection rule (token scope still blocks push).  
2. Drop the HTTP push-deny rule (optional anyway).  
3. Replace the in-sandbox loop with a host-side loop: `sbx create --name reviewer ... ./kits/reviewer` once, then a host script that runs `sbx exec reviewer bash /home/agent/review-one.sh <N>` per PR. Same footer, same Skill.  
4. Pre-open the PR before the call and demo only the reviewer path live (developer path shown as a recording).  
5. Last resort: whole thing as a recording, with `sbx policy check` and `sbx exec reviewer gh auth status` run live to prove the environment is real.

---

## 9\. Reference — verbatim syntax from docs.docker.com (fetched Sept 29, 2026\)

**Run / create**

```
sbx run [flags] [AGENT|SANDBOX_KIT] [PATH...] [-- AGENT_ARGS...]
sbx create [flags] AGENT|SANDBOX_KIT [PATH...]      # omit PATH for mountless
sbx run --name my-sandbox claude -- "prompt text"     # everything after -- goes to Claude Code
sbx run ./claude-safe                                 # v2 sandbox kit in place of agent name
sbx run claude --name claude-project --kit ./team-config   # v2 mixin on a built-in
sbx run --name existing-sandbox                       # re-attach
sbx exec [-it] [-u user] [-w dir] [-e K=V] SANDBOX COMMAND [ARG...]
sbx ls [--json] [-q]; sbx stop NAME; sbx rm [--force] NAME; sbx prune
```

Flags: `--name`, `--clone`, `-e/--env` (≥0.39), `--env-file`, `--deny-network HOST` (≥0.38, repeatable), `--skills off|readonly|readwrite`, `-t/--template`, `--cpus`, `-m/--memory`, `-d/--detached`, `--pull always|missing|never`. `--ttl`, `--on-timeout`, `sbx ttl` are **cloud only** — local sandboxes have no TTL.

Default Claude Code startup command inside a sandbox: `claude --dangerously-skip-permissions`. Headless inside the sandbox: `claude -p "..."`. Sandboxes do not pick up host `~/.claude`; only project-level config in the working directory (and files the kit places under `/home/agent`).

**Kits (v2)**

- `spec.yaml` with `schemaVersion: "2"`, `kind: sandbox|mixin`, `extends: claude`, `sandbox.entrypoint: [..]`, `agentInstructions{filename,content}`, `permissions.network.allow/deny`, `credentials[]{service, apiKey{name, proxyManaged, inject[]{domain, scheme}}}`, `environment.variables`, `setup.install[]`, `setup.startup[]`, `setup.files[]`.  
- Static files: `files/home/` → `/home/agent/`; `files/workspace/` → primary workspace. Project skill: `files/workspace/.claude/skills/<NAME>/SKILL.md`; user-level alternative `files/home/.claude/skills/<NAME>/SKILL.md`.  
- Do not touch sandbox-managed paths for claude: `~/.claude.json`, `~/.claude/settings.json`, `~/.claude/.config.json`.  
- "a child of `claude` that adds `--settings` must also include `--dangerously-skip-permissions` to preserve that behavior."  
- Deny takes precedence over allow, including across composed kits.  
- `sbx kit validate <path>`; `sbx kit inspect [--json]`. All `sbx kit` commands are experimental.  
- Kit sources allowed by default: local directories and Docker Hub. `sbx settings set kit.allowedSources '[...]'` to widen.

**Credentials**

```
echo "$ANTHROPIC_API_KEY" | sbx secret set anthropic
sbx secret set github --sandbox <name> --command 'gh auth token'
sbx secret set github --sandbox <name> -t <TOKEN>
sbx secret ls; sbx secret rm github --sandbox <name>
```

Built-in services: `anthropic` (`ANTHROPIC_API_KEY`; api.anthropic.com, console.anthropic.com, claude.ai, mcp-proxy.anthropic.com), `github` (`GH_TOKEN`, `GITHUB_TOKEN`; api.github.com, github.com, raw.githubusercontent.com, gist.github.com, copilot.github.com, api.githubcopilot.com). Sandbox-scoped secrets take precedence over global. Secret changes apply to running local sandboxes without restart. The sandbox only ever sees a sentinel; the host proxy injects the real header.

Credential bindings for third-party kits, `~/.config/sbx/credentials.yaml`:

```
bindings:
  anthropic:
    apiKey:
      domains: [api.anthropic.com]
  github:
    apiKey:
      domains: [api.github.com, github.com]
```

Without a binding, a non-interactive run starts with the credential **withheld** and only prints a warning.

**Network policy**

```
sbx policy init allow-all|balanced|deny-all
sbx policy allow network HOST[,HOST...]  [--sandbox NAME]  [--method GET,POST|ANY] [--path '/x/**']
sbx policy deny  network HOST            [--sandbox NAME]  [--method ...] [--path ...]
sbx policy ls [NAME] [--wide] [--source local|org|kit] [--type network|http] [--decision allow|deny]
sbx policy check network [--sandbox NAME] HOST
sbx policy log [NAME] [--json] [--limit N] [--type all|network|filesystem]
sbx policy rm network --resource HOST [--sandbox NAME]
```

Patterns: `example.com` (exact, not subdomains), `*.example.com` (one level), `**.example.com` (any depth), `example.com:443`. Deny wins; default deny. Under org governance only org **allow** rules grant access; local and kit allow rules are inactive; deny rules from every source still apply. Org policy propagation up to 5 minutes. `sbx policy check` and `sbx policy log` do not evaluate HTTP method/path rules.

**Audit (local)** Written only for signed-in users with an AI Governance license under enforced centralized policy. macOS path: `~/Library/Logs/com.docker.sandboxes/sandboxes/auditkit/audit-*.jsonl` (only `.jsonl` files are complete). Fields include `timestamp`, `category`, `decision`, `username`, `user_email`, `org_name`, `audit_session_id`, `resource_id`, `action_type` (e.g. `network_egress`), `deny_reason`, `agent`. Records are metadata only: no prompt content or agent output. No `sbx` command reads them; use `jq`/`grep`.

---

## 10\. Known risks

- **`extends: claude` credential inheritance** is inferred, not confirmed in the docs. If the reviewer gets no GitHub token, add an explicit `credentials:` block to both kits.  
- **Org governance on Jeremy's Docker account** would disable kit allow rules. The reviewer lockdown survives (deny rules), the developer's reach becomes the org allow list. Check first (section 6, Environment).  
- **Reviewer loop as entrypoint** replaces Claude Code as the sandbox's main process. If the runtime expects the agent binary as PID 1 for any reason, fall back to the host-side loop (section 8, item 3).  
- **Fine-grained PAT on a machine user** needs the machine user to have repo access; a collaborator invite must be accepted from that account.  
- **Live network dependency**: GitHub, Anthropic, and the Docker proxy all have to be up. Record the fallback.  
- **Pre-1.0 CLI**: flags marked experimental may shift. Section 9 is what the docs said on Sept 29; trust actual `--help` output over this file if they disagree, and record the difference.