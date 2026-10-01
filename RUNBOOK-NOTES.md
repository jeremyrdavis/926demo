# Runbook notes — Iteration 1

Companion to `Iteration_1_-_Spec_and_Checklist.md`. Section 4 was authored inside a sandbox with no `sbx` CLI, so the section 6 checklist below is split into what was verified there and what still has to be run on the Mac. Nothing under "Run on the Mac" is checked off until someone has run it.

**Fill in on the Mac:** `sbx version` = `______` · governance = `not governed / Managed by ______` · audit `.jsonl` present = `yes / no`

## Authored and verified in the authoring sandbox

- [x] `kits/developer/` written per 4.2 (`spec.yaml` v2 plus `implementer` skill). YAML parses; fields match the spec. `sbx kit validate` not run.
- [x] `kits/reviewer/` written per 4.3–4.6 (`spec.yaml`, `reviewer-loop.sh` executable, `review-prompt.md`, `code-review` v1.0.0 skill). YAML parses; `bash -n` clean.
- [x] `reviewer-loop.sh` exercised offline against stub `gh` and `claude`: startup logs, PR pickup, checkout, `claude -p` exit code, environment-notes echo, comment post, state file written only after the comment, restart does not re-review, footer matches 4.5. Not tested against real GitHub, real `claude`, or as an `sbx` entrypoint.
- [x] `sbx-demo-app/` written per 4.1. `pytest -q`: 9 passed (Python 3.14.4, deps installed with `pip --target`; not run on the Mac). No test covers `apply_discount`, on purpose.

## Run on the Mac (in order)

Every `sbx` line matches spec section 9. If any output differs from the spec, stop and record the actual output.

### Environment

- [x] `sbx version` (need ≥ 0.42). Record above.
- [x] `sbx login`, then `sbx ls` succeeds.
- [x] `sbx policy ls`. If it does **not** say `Governance: Managed by <org>`: `sbx policy init deny-all`, then `sbx policy check network pypi.org` → Denied. If governed: skip `init` (kit allow rules are inactive; kit deny rules still apply).
- [ ] `echo "$ANTHROPIC_API_KEY" | sbx secret set anthropic`, then `sbx secret ls` shows `(global) service anthropic`.
- [x] `ls ~/Library/Logs/com.docker.sandboxes/sandboxes/auditkit/`. Record whether `.jsonl` files exist.

### GitHub

- [ ] Publish `sbx-demo-app/` as its own repo, not as a subdirectory of this one. For example: `cp -R sbx-demo-app ~/src/sbx-demo-app && cd ~/src/sbx-demo-app && git init -b main && git add -A && git commit -m "chore: initial commit" && gh repo create <owner>/sbx-demo-app --private --source . --push`. Then `pip install -r requirements.txt && pytest -q` is green on the Mac.
- [ ] Branch protection on `main`: require 1 approving review (repo Settings → Branches).
- [ ] Create machine user `acme-reviewer-bot`, invite as collaborator with **Read**, accept the invite from that account.
- [ ] Fine-grained PAT on `acme-reviewer-bot`: resource owner = repo owner, repo = `sbx-demo-app` only, Contents read, Pull requests read/write, Metadata read, expiry 7 days.
  - `GH_TOKEN=<pat> gh api repos/<owner>/sbx-demo-app/pulls` works.
  - `GH_TOKEN=<pat> gh api -X PUT repos/<owner>/sbx-demo-app/contents/x` → 403.

### Kits and credentials

- [ ] `sbx kit validate ./kits/developer` and `sbx kit validate ./kits/reviewer`.
- [ ] Create credential bindings: run each kit interactively once, or write `~/.config/sbx/credentials.yaml` (format in spec section 9). `cat` it and confirm `anthropic` and `github` bindings.
- [ ] `sbx secret set github --sandbox developer --command 'gh auth token'`
- [ ] `sbx secret set github --sandbox reviewer -t <PAT>`. If `--sandbox` is rejected before the sandbox exists, use `sbx create --name <name> ...` first (spec 4.7). Then `sbx secret ls` shows two sandbox-scoped `github` entries and **no** global `github`.

### Reviewer sandbox

- [ ] `sbx run --name reviewer --skills=off -e REPO=<owner>/sbx-demo-app -e POLL_SECONDS=30 ./kits/reviewer`. Add `-e SBX_VERSION=<version from sbx version>` if you want the real version in the footer (see deviations). Log shows `polling <repo> every 30s` and no errors for two cycles.
- [ ] `sbx policy ls reviewer --wide`: allow list is github.com, api.github.com, api.anthropic.com (plus anything the built-in claude kit adds); deny list includes pypi.org.
- [ ] `sbx policy check network --sandbox reviewer pypi.org` → Denied; `... api.github.com` → Allowed.
- [ ] `sbx exec reviewer gh auth status` → `acme-reviewer-bot`, not Jeremy.
- [ ] `sbx exec reviewer -w /home/agent/workspace sh -c 'gh repo clone <owner>/sbx-demo-app t && cd t && git push origin HEAD:refs/heads/probe'` → fails with 403. Clean up `t`.
- [ ] `sbx exec reviewer pip download pydantic` → blocked; `sbx policy log reviewer` shows a DENY for pypi.org.

### Developer sandbox

- [ ] Clone the repo to `~/src/sbx-demo-app` on `main` (done above if you used the `cp` route).
- [ ] `sbx run --name developer --skills=off ./kits/developer ~/src/sbx-demo-app -- "Implement specs/001-discount-codes.md using the implementer skill."` A PR appears, authored by Jeremy, branch `feat/001-discount-codes`, body links the spec.
- [ ] `sbx exec developer gh auth status` → Jeremy.

### End to end

- [ ] Within 30–60 s of the PR opening, the reviewer log shows pickup, checkout, `claude -p`, the "review says: … Environment notes …" line, and the comment URL.
- [ ] On GitHub: comment by `acme-reviewer-bot`, with the 4.5 footer and an Environment notes line about the blocked install.
- [ ] `sbx policy log reviewer --json | jq 'select(.decision=="deny")'` shows the pypi DENY inside the review window.
- [ ] If audit `.jsonl` exists: `grep -l '"resource_id": "pypi.org' ~/Library/Logs/com.docker.sandboxes/sandboxes/auditkit/*.jsonl` finds a record with `username` = Jeremy and `agent` = claude.
- [ ] Reset: close the PR, delete the branch, `sbx rm --force developer`, clear the PR number from the reviewer's `/home/agent/state/handled.txt` (or `sbx rm --force reviewer` and relaunch). Run again clean. Section 7 must run clean twice.
- [ ] Record a full clean run (both terminals and the browser) as the fallback. Then run the section 7 runbook.

## Deviations, additions and things to watch

Things the spec did not pin down, or where the built loop goes beyond it:

- **Footer `sbx` version:** `sbx` isn't available inside the sandbox, so the loop reads it from an optional `SBX_VERSION` env var and otherwise prints `unknown`. Passing it is one more documented `-e` flag on the reviewer launch line; skip it if you prefer the spec's launch line verbatim.
- **Footer model:** uses `$ANTHROPIC_MODEL` if set, else the literal `Claude Code default`. It does not parse `claude` output.
- **Footer sandbox name:** uses `$SANDBOX_NAME` (falls back to `reviewer`). Confirm on the first run that it renders `reviewer`.
- **Extra log lines in `reviewer-loop.sh`:** the GitHub identity at startup, and a "review says: …" line echoing the Environment notes, which makes the pip block visible in the terminal for beat 4.
- **Retry cap:** a PR that fails to review is retried at most 3 times per loop process, so a broken PR doesn't burn API calls every 30 s. The PR is not written to the state file; a sandbox restart resets the counter.
- **Spec 001 details I chose:** results rounded to 2 places; codes are case-sensitive; a negative `total` raises `ValueError`; `apply_discount` goes in `app/inventory.py`.
- **`extends: claude` credential inheritance** is still unconfirmed (spec section 10). If the reviewer has no GitHub token, add an explicit `credentials:` block to both kits.
- **Loop as entrypoint** replacing the agent as PID 1 is still untested. Fallback is spec section 8, item 3.
- `sbx-demo-app/` here contains its own `CLAUDE.md`. It is meant for the standalone demo repo, not this one.
