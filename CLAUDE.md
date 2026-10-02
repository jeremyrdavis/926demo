# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## State of the repo

Section 4 of the spec is authored (kits, loop script, demo app contents). Section 6 verification is only partly done, because the authoring sandbox has no `sbx` CLI. `RUNBOOK-NOTES.md` tracks which checklist items were verified and which still have to be run on the Mac; don't mark host-side items done without running them.

`Iteration_1_-_Spec_and_Checklist.md` (the kickoff prompt inside it refers to it as `Iteration 1 - Spec and Checklist.md`; the real filename uses underscores) is the source of truth. It defines the components, the build order (section 6), the demo runbook (section 7) and a verbatim `sbx` syntax reference (section 9). There is no build or lint tooling. The parent-directory `CLAUDE.md` covers the sandbox environment (proxy, git auth, port publishing) and is not repeated here.

Offline checks that work without `sbx`: `bash -n kits/reviewer/files/home/reviewer-loop.sh`, parsing the two `spec.yaml` files, and `pytest -q` in `sbx-demo-app/` (needs `pytest` and `pydantic`; the authoring sandbox has no `venv`, so `pip install --break-system-packages --target <dir>` plus `PYTHONPATH` worked). To test the loop, put stub `gh` and `claude` scripts first on `PATH` and set `REVIEWER_HOME`, `REPO` and `POLL_SECONDS`.

## What this project is

A live demo (target: Wednesday 2026-09-30) of an agent acting on behalf of a user, built on Docker Sandboxes (`sbx`). Two sandboxes run the same agent (Claude Code) under two different **kits** with different blast radii:

- **developer**: broad network policy and the user's own GitHub token. It implements `specs/001-discount-codes.md` in a demo repo, pushes, and opens a PR.
- **reviewer**: a long-running sandbox with no host mount. It polls GitHub every 30s and reviews each new PR under a versioned `code-review` Skill. **Iteration 1 basic flow (decided 2026-10-01):** it runs under the user's own GitHub account `jeremyrdavis`, same as the developer; the separate `acme-reviewer-bot` identity with a read/comment-only PAT, the GitHub org that requires, and branch protection are deferred to iteration 2 (list at the end of `RUNBOOK-NOTES.md`). The Skill deliberately tells it to `pip install` and run tests. Network policy denies PyPI, so the agent notes the block and falls back to static review. That denial (visible in `sbx policy log`) is the point of the demo, so **do not remove that Skill step**.

The audience should see Docker machinery (kit files, policy checks, the DENY log entry, a bot-authored comment with a traceability footer), not Claude output.

## Layout

- `kits/developer-mixin/` and `kits/reviewer-mixin/`: the **primary** kits. v2 `kind: mixin`, layered onto the built-in `claude` agent with `sbx run ... --kit <dir> claude` so Claude Code keeps using the user's OAuth login (proxy-managed OAuth is unsupported for kits that replace the agent). No `anthropic` secret is needed.
- `kits/developer/` and `kits/reviewer/`: the API-key **fallback**, v2 `kind: sandbox` with `extends: claude`. Same `files/home/` trees and the same instructions and network rules as the mixins. `sbx kit validate` rejects `sandbox.entrypoint` and ignores `agentInstructions.filename` on a mixin, so only the fallback kits carry those two fields. Keep the pairs in sync when editing either.
- All four kits place `files/home/...` at `/home/agent/`.
  - Reviewer files: `reviewer-loop.sh`, `review-prompt.md`, and `.claude/skills/code-review/SKILL.md`.
  - Developer files: `.claude/skills/implementer/SKILL.md`.
- `sbx-demo-app/`: the contents of the **separate** GitHub repo `<owner>/sbx-demo-app` (small Python service plus pytest, with `specs/001-discount-codes.md`). It is staged here only for authoring. It must be published as its own repo and cloned to `~/src/sbx-demo-app`, which is what gets bind-mounted into the developer sandbox. It has its own `CLAUDE.md` meant for that repo.
- `RUNBOOK-NOTES.md`: the section 6 checklist split into verified and to-run-on-the-Mac, plus deviations from the spec.

## Architecture points that span files

- The reviewer runs `reviewer-loop.sh` inside its sandbox. With the mixin kit it is started by `sbx exec reviewer bash /home/agent/reviewer-loop.sh` after `sbx create`; with the fallback kit it is the `sandbox.entrypoint`. Either way it clones each PR to `/home/agent/workspace/pr-N`, runs `claude -p` against `review-prompt.md` (with `{{PR}}`/`{{OUT}}` substituted), then **the script, not the agent**, appends the traceability footer and posts via `gh pr comment --body-file`.
  - State is kept in `/home/agent/state/handled.txt`, and a PR is recorded only after its comment succeeds.
  - Use `set -u`, not `set -e`, so one failed review doesn't kill the loop.
  - The footer text is specified in spec section 4.5. `BOT_LOGIN` defaults to the login `gh api user` reports. The spec's last line ("cannot push, approve, or merge") prints only when `REVIEWER_LOCKED_DOWN=1`; otherwise a softened line names whose permissions the agent runs with. Never set the flag unless the token genuinely cannot push.
- Lockdown is layered:
  - The PAT scope limits what the token can do.
  - Kit `deny` rules on the registries survive even under org governance, where kit `allow` rules are inactive.
  - Branch protection on `main` requires one approving review.
- Credentials: the sandbox only ever sees a sentinel, and the host proxy injects the real header.
  - **Never set a global `github` secret.** Use sandbox-scoped ones (`sbx secret set github --sandbox <name> -t "$(gh auth token --user jeremyrdavis)"`), because a global one silently hands any sandbox without a scoped secret whatever the host is logged in as. This happened on 2026-10-01 (a stale global entry made the reviewer `jeremydavisdocker`); the global entry was removed. The host `gh` has two logins, so always pass `--user`. Use the literal `-t "$(…)"` form, not `--command`: the daemon can't read `gh`'s Keychain token and injects an invalid one. Scoped secrets are deleted with their sandbox, so re-set after every `sbx rm`. Verify with `sbx secret ls` and `sbx exec <name> gh auth status`.
  - Claude Code auth is the user's OAuth login, carried through by the sbx proxy because the mixin kits leave the built-in `claude` agent in place. Only the fallback `extends: claude` kits need `ANTHROPIC_API_KEY` via `sbx secret set anthropic`. Both agents share one subscription allowance, so watch for session limits during a long reviewer poll.
  - Third-party kits need bindings in `~/.config/sbx/credentials.yaml`. Without one, a non-interactive run starts with the credential withheld and only prints a warning.
- `extends: claude` inheriting the built-in `anthropic`/`github` credential declarations is inferred, not confirmed. If the reviewer gets no GitHub token, add an explicit `credentials:` block to both kits.

## Offline verification (no `sbx` needed)

There is no build or lint tooling. These are the only checks that run without the `sbx` CLI, so they're what to run after editing anything under `kits/` or `sbx-demo-app/`:

```bash
bash -n kits/reviewer/files/home/reviewer-loop.sh   # syntax-check the entrypoint
for k in kits/*/spec.yaml; do python3 -c "import sys, yaml; yaml.safe_load(open(sys.argv[1]))" "$k" && echo "$k ok"; done   # pyyaml may need the same pip --target trick

cd sbx-demo-app
pip install --break-system-packages --target .deps -r requirements.txt   # if pytest/pydantic aren't already available
PYTHONPATH=.deps pytest -q
```

To exercise `reviewer-loop.sh` itself, put stub `gh` and `claude` scripts first on `PATH` and set `REVIEWER_HOME`, `REPO`, and `POLL_SECONDS` before running it; it reads GitHub PR state through `gh` and runs reviews through `claude -p`, so stubbing both lets you drive it through a full poll/review/comment cycle without either real dependency.

## Commands

Every `sbx` invocation must match spec section 9. Do not invent flags, and trust `sbx ... --help` over the spec if they disagree (then record the difference). If a documented command behaves differently, stop, show the actual output, and propose the smallest workaround.

```bash
sbx kit validate ./kits/developer-mixin      # also ./kits/reviewer-mixin and the two fallback kits; all `sbx kit` commands are experimental
sbx create --name reviewer --skills=off --kit ./kits/reviewer-mixin claude   # mountless
sbx exec -e REPO=<owner>/sbx-demo-app -e POLL_SECONDS=30 reviewer bash /home/agent/reviewer-loop.sh
sbx run --name developer --skills=off --kit ./kits/developer-mixin claude ~/src/sbx-demo-app -- "Implement specs/001-discount-codes.md using the implementer skill."
# API-key fallback: sbx run --name reviewer --skills=off -e REPO=... -e POLL_SECONDS=30 ./kits/reviewer
#                   sbx run --name developer --skills=off ./kits/developer ~/src/sbx-demo-app -- "..."
sbx exec reviewer gh auth status             # jeremyrdavis in iteration 1; acme-reviewer-bot once iteration 2 lands
sbx policy check network --sandbox reviewer pypi.org   # expect Denied; api.github.com expect Allowed
sbx policy log reviewer --json | jq 'select(.decision=="deny")'
sbx secret ls                                # two sandbox-scoped github entries, no global github
sbx rm --force developer                     # reset between runs (also clear the PR number from handled.txt, or rm/relaunch reviewer)
```

Check `sbx policy ls` first: if it reports `Governance: Managed by <org>`, do not run `sbx policy init`. Otherwise run `sbx policy init deny-all`. `sbx version` must be at least 0.42 (mountless create).

## Constraints

- Use kit **schema v2** only. Do not mix v2 and v3 in one sandbox (v3 is for iteration 2).
- Both sandboxes are launched with `--skills=off`, so the shared skills store doesn't mount over the kit-provided skill.
- Don't touch sandbox-managed Claude paths: `~/.claude.json`, `~/.claude/settings.json`, `~/.claude/.config.json`.
- Non-goals for iteration 1, not to be started before the section 7 runbook runs clean twice: Slack, coordinator, Hermes, GitHub App, cloud sandboxes (`--cloud`), org policy authoring, CI runner.
- Be honest about the identity story in anything demo-facing: both sandboxes run under the user's **Docker** identity and, in iteration 1, the same **GitHub** identity too. What differs between them is network policy and kit contents. A distinct reviewer GitHub identity (a strict subset of permissions) arrives in iteration 2. Don't claim a distinct Docker agent identity, and don't promise audit `.jsonl` records unless the org has AI Governance with enforced policy (check `~/Library/Logs/com.docker.sandboxes/sandboxes/auditkit/`).
- Spec section 8 lists the scope-cut order if time runs short. If the in-sandbox loop fails because the runtime needs the agent binary as PID 1, fall back to a host-side loop using `sbx exec`.
