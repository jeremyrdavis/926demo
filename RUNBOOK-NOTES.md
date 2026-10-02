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
- [ ] ~~`echo "$ANTHROPIC_API_KEY" | sbx secret set anthropic`~~ **Superseded (2026-10-01):** staying on Claude Code OAuth instead of an API key. Proxy-managed OAuth is unsupported for kits that `extends: claude`, so the primary kits are now the `kind: mixin` variants in `kits/developer-mixin` and `kits/reviewer-mixin`, layered onto the built-in `claude` agent with `--kit`. No `anthropic` secret is needed. The `extends: claude` kits stay as the API-key fallback.
  - [x] Verified 2026-10-01: the reviewer sandbox created from the mixin runs Claude Code on OAuth; `sbx secret ls` shows `(global) service anthropic (oauth configured)` and no API key was set. If this ever stops working, fall back to the original kits and the `sbx secret set anthropic` line above.
- [x] `ls ~/Library/Logs/com.docker.sandboxes/sandboxes/auditkit/`. Record whether `.jsonl` files exist.

### GitHub

**Iteration 1 basic flow (decided 2026-10-01):** both sandboxes run under Jeremy's personal GitHub account `jeremyrdavis`, which owns `jeremyrdavis/sbx-demo-app`. The separate reviewer identity (machine user, org, fine-grained PAT) and branch protection are deferred; see "Deferred to iteration 2" at the end. The blast-radius difference between the two sandboxes is therefore network policy and kit contents only, and the footer says so.

- [x] Published as `jeremyrdavis/sbx-demo-app` (personal account). `pytest -q` green on the Mac.

### Kits and credentials

- [x] `sbx kit validate ./kits/developer-mixin` → VALID (2026-10-01). It warned that `agentInstructions.filename` is ignored for mixins (content is still merged), so `filename` was removed from both mixins.
- [ ] `sbx kit validate ./kits/reviewer-mixin` → re-run after the fix. The first run failed: `'sandbox:' block is only valid for kind "sandbox", not "mixin"`, so the entrypoint was removed and the loop is now started with `sbx exec` (see Reviewer sandbox below).
- [ ] `sbx kit validate ./kits/developer` and `./kits/reviewer` if keeping the API-key fallback warm.
- [ ] Create credential bindings: run each kit interactively once, or write `~/.config/sbx/credentials.yaml` (format in spec section 9). `cat` it and confirm `anthropic` and `github` bindings.
- [x] `sbx secret set github --sandbox reviewer -t "$(gh auth token --user jeremyrdavis)"` (verified 2026-10-02: `sbx exec reviewer gh auth status` → `jeremyrdavis`; loop startup line shows the same). The host `gh` is logged in as both `jeremydavisdocker` and `jeremyrdavis`; `--user` picks the right one.
  - Demo material: `sbx exec reviewer printenv GH_TOKEN` prints the sentinel `gho_sbxproxymanaged000000000000000000000` while `gh` inside the sandbox works. The real token never enters the sandbox; the proxy injects it per request.
  - With the global `github` row removed, it did **not** reappear after the sandbox was restarted, so sbx does not re-create it; the earlier reappearance was an incomplete removal. The "no global `github` secret" rule stands.
  - **Do not use the `--command 'gh auth token …'` form (observed 2026-10-02).** With it, `gh auth status` inside the sandbox reported "The token in GH_TOKEN is invalid". The daemon runs the command outside a user session and apparently cannot read `gh`'s Keychain-stored token, so an empty or bad value gets injected. The literal `-t "$(…)"` form, evaluated in your own shell, is the one that works; `gho_` tokens do not expire, so the snapshot is fine.
- [ ] `sbx secret set github --sandbox developer -t "$(gh auth token --user jeremyrdavis)"`. If `--sandbox` is rejected before the sandbox exists, `sbx create` it first (see Developer sandbox). Then `sbx secret ls` shows two sandbox-scoped `github` entries and **no** `(global) github` row.
  - **Observed 2026-10-01:** a pre-existing `(global) service github` entry from earlier, unrelated sandboxes made the reviewer authenticate as `jeremydavisdocker`. The global entry was removed with `sbx secret rm github`. Any other sandbox that relied on it needs its own scoped secret now. With no global entry, a sandbox with no scoped `github` secret has no GitHub token at all, which is the intended failure mode.

### Reviewer sandbox

- [x] Create the sandbox mountless from the mixin, then start the loop inside it with `sbx exec` (a mixin cannot set `sandbox.entrypoint`, confirmed by `sbx kit validate` on 2026-10-01). Both verified working 2026-10-01:
  ```bash
  sbx create --name reviewer --skills=off --kit ./kits/reviewer-mixin claude
  sbx exec -e REPO=jeremyrdavis/sbx-demo-app -e POLL_SECONDS=30 reviewer bash /home/agent/reviewer-loop.sh
  ```
  Keep that second terminal open; it is the reviewer log for the demo. The startup line now reads `authenticated to GitHub as <login> (footer identity: <login>, locked down: 0)`. Add `-e SBX_VERSION=<version from sbx version>` for the real version in the footer (see deviations). Do **not** pass `REVIEWER_LOCKED_DOWN=1` in iteration 1; the token can push. API-key fallback (loop as entrypoint): `sbx run --name reviewer --skills=off -e REPO=jeremyrdavis/sbx-demo-app -e POLL_SECONDS=30 ./kits/reviewer`.
- [x] After updating `reviewer-loop.sh` (footer change, 2026-10-01) the running sandbox still had the old copy; recreated with `sbx rm --force reviewer` and the two lines above.
- **Rule (confirmed 2026-10-02): sandbox-scoped secrets are deleted with the sandbox.** After the recreate, `sbx secret ls` had no `reviewer` row and the loop authenticated as `jeremydavisdocker` again. Every `sbx rm` of `reviewer` or `developer` must be followed by the matching `sbx secret set github --sandbox <name> -t "$(gh auth token --user jeremyrdavis)"` **before** the loop or Claude Code starts, then `sbx exec <name> gh auth status` to confirm. The reviewer loop captures its footer identity at startup, so restart the `sbx exec` loop after fixing a secret.
- [x] `sbx policy ls reviewer --wide`: allow list is github.com, api.github.com, api.anthropic.com (plus anything the built-in claude kit adds); deny list includes pypi.org.
- [x] `sbx policy check network --sandbox reviewer pypi.org` → Denied; `... api.github.com` → Allowed.
- [x] `sbx exec reviewer gh auth status` → `jeremyrdavis` (iteration 1; `acme-reviewer-bot` in iteration 2).
- [x] `sbx exec reviewer pip download pydantic` → blocked; `sbx policy log reviewer` shows a DENY for pypi.org.
- Push probe (`git push origin HEAD:refs/heads/probe` from inside the reviewer → 403) is deferred to iteration 2; under the personal token it would succeed.

### Developer sandbox

- [ ] Clone the repo to `~/src/sbx-demo-app` on `main` (done above if you used the `cp` route).
- [ ] Create first so the scoped secret exists before Claude Code's first `gh` call (there is no global `github` secret to fall back on any more):
  ```bash
  sbx create --name developer --skills=off --kit ./kits/developer-mixin claude ~/src/sbx-demo-app
  sbx secret set github --sandbox developer -t "$(gh auth token --user jeremyrdavis)"
  sbx exec developer gh auth status        # jeremyrdavis
  sbx run --name developer -- "Implement specs/001-discount-codes.md using the implementer skill."
  ```
  If `sbx run --name <existing>` rejects the `--` prompt on re-attach, run `sbx run --name developer` and type the prompt at the Claude Code prompt (typing it live works fine on stage). API-key fallback: `sbx run --name developer --skills=off ./kits/developer ~/src/sbx-demo-app -- "..."`. A PR appears, authored by `jeremyrdavis`, branch `feat/001-discount-codes`, body links the spec.

### End to end

- [ ] Within 30–60 s of the PR opening, the reviewer log shows pickup, checkout, `claude -p`, the "review says: … Environment notes …" line, and the comment URL.
- [ ] On GitHub: comment by `jeremyrdavis` (same account as the PR author; GitHub allows commenting, not approving, your own PR), with the 4.5 footer whose last line reads "configured to comment only … runs with @jeremyrdavis's GitHub permissions", and an Environment notes line about the blocked install.
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
- **Footer identity and last line (2026-10-01):** `BOT_LOGIN` now defaults to the login `gh api user` reports, so the footer names whoever actually posted. The spec 4.5 last line ("cannot push, approve, or merge") prints only when `REVIEWER_LOCKED_DOWN=1` is passed; otherwise the footer says "This agent is configured to comment only. It currently runs with @<login>'s GitHub permissions." Set the flag only when the token genuinely cannot push (bot PAT, or the spec 4.7 proxy deny on `git-receive-pack`). Verified offline against stub `gh`/`claude` in both modes.
- **Retry cap:** a PR that fails to review is retried at most 3 times per loop process, so a broken PR doesn't burn API calls every 30 s. The PR is not written to the state file; a sandbox restart resets the counter.
- **Spec 001 details I chose:** results rounded to 2 places; codes are case-sensitive; a negative `total` raises `ValueError`; `apply_discount` goes in `app/inventory.py`.
- **Mixin kits (2026-10-01):** `kits/developer-mixin` and `kits/reviewer-mixin` are `kind: mixin` so Claude Code can keep using Jeremy's OAuth login via the built-in `claude` agent instead of an API key. Differences from the `extends: claude` kits, all forced by `sbx kit validate`: `kind: mixin`, no `extends:`, no `agentInstructions.filename`, and no `sandbox.entrypoint`. Consequence: the reviewer loop is started by `sbx exec` from the host instead of being PID 1. It still runs inside the sandbox under the sandbox's network policy and GitHub credential, so the demo beats are unchanged; only the launch is two commands instead of one. Verified 2026-10-01: proxy-managed OAuth flows with `--kit`, and `sbx exec` works right after `sbx create`. The same fallthrough means a sandbox with no scoped `github` secret silently uses whatever global GitHub credential the host has, so the reviewer's identity must be set explicitly every time the sandbox is recreated. Both agents consume the same subscription allowance, so a long reviewer poll plus a developer run could hit a session limit mid-demo.
- **`extends: claude` credential inheritance** is still unconfirmed (spec section 10). If the reviewer has no GitHub token, add an explicit `credentials:` block to both kits.
- **Loop as entrypoint** only applies to the API-key fallback kit now, and is still untested there. The mixin path uses `sbx exec` instead; spec section 8, item 3 (host-side loop) remains the last resort.

## Deferred to iteration 2

Cut on 2026-10-01 to get the basic flow running clean first. Pick up in this order; each step is verifiable on its own.

1. **Free GitHub organization** (working name `acme-sbx-demo`) owned by `jeremyrdavis`; transfer `sbx-demo-app` into it; set org base permissions to *No permission*; allow fine-grained PATs under org Settings → Third-party Access. Needed because a fine-grained PAT can only target repos owned by its resource owner, and a personal repo gives every collaborator write access. Afterwards: `git remote set-url origin` in `~/src/sbx-demo-app`, and `REPO=<org>/sbx-demo-app` on the reviewer launch.
2. **Machine user `acme-reviewer-bot`** (plus-address email, 2FA, display name), org member with **Read** on the repo.
3. **Fine-grained PAT** on the bot: resource owner = the org, only `sbx-demo-app`, Contents read, Pull requests read/write, Metadata read, short expiry. Verify: `GH_TOKEN=<pat> gh api user --jq .login` → bot; `gh api repos/<org>/sbx-demo-app/pulls` → 200; `gh api -X PUT repos/<org>/sbx-demo-app/contents/x -f message=probe -f content=eA==` → 403. Then `sbx secret set github --sandbox reviewer -t <pat>`, relaunch the loop with `-e REVIEWER_LOCKED_DOWN=1`, and run the push probe from inside the reviewer (expect 403).
4. **Branch protection on `main`** (1 approving review). Only meaningful once the reviewer is a different account, since you cannot approve your own PR. GitHub Free allows it on public repos only:
   ```bash
   gh api -X PUT repos/<org>/sbx-demo-app/branches/main/protection --input - <<'EOF'
   { "required_status_checks": null, "enforce_admins": true,
     "required_pull_request_reviews": { "required_approving_review_count": 1, "dismiss_stale_reviews": false },
     "restrictions": null }
   EOF
   ```
   Bypass during a reset: `gh api -X DELETE repos/<org>/sbx-demo-app/branches/main/protection/enforce_admins`.
5. Optional, Docker-native alternative to 3 for the "cannot push" guarantee: `sbx policy deny network --sandbox reviewer github.com --method POST --path '/**/git-receive-pack'` (spec 4.7). `sbx policy check/log` do not evaluate method/path rules, so verify with a real push attempt.
- `sbx-demo-app/` here contains its own `CLAUDE.md`. It is meant for the standalone demo repo, not this one.
