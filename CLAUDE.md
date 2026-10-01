# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## State of the repo

Section 4 of the spec is authored (kits, loop script, demo app contents). Section 6 verification is only partly done, because the authoring sandbox has no `sbx` CLI. `RUNBOOK-NOTES.md` tracks which checklist items were verified and which still have to be run on the Mac; don't mark host-side items done without running them.

`Iteration_1_-_Spec_and_Checklist.md` (the kickoff prompt inside it refers to it as `Iteration 1 - Spec and Checklist.md`; the real filename uses underscores) is the source of truth. It defines the components, the build order (section 6), the demo runbook (section 7) and a verbatim `sbx` syntax reference (section 9). There is no build or lint tooling. The parent-directory `CLAUDE.md` covers the sandbox environment (proxy, git auth, port publishing) and is not repeated here.

Offline checks that work without `sbx`: `bash -n kits/reviewer/files/home/reviewer-loop.sh`, parsing the two `spec.yaml` files, and `pytest -q` in `sbx-demo-app/` (needs `pytest` and `pydantic`; the authoring sandbox has no `venv`, so `pip install --break-system-packages --target <dir>` plus `PYTHONPATH` worked). To test the loop, put stub `gh` and `claude` scripts first on `PATH` and set `REVIEWER_HOME`, `REPO` and `POLL_SECONDS`.

## What this project is

A live demo (target: Wednesday 2026-09-30) of an agent acting on behalf of a user, built on Docker Sandboxes (`sbx`). Two sandboxes run the same agent (Claude Code) under two different **kits** with different blast radii:

- **developer**: broad network policy and the user's own GitHub token. It implements `specs/001-discount-codes.md` in a demo repo, pushes, and opens a PR.
- **reviewer**: a long-running sandbox with no host mount. It polls GitHub every 30s and reviews each new PR under a versioned `code-review` Skill. It runs as a separate GitHub identity (`acme-reviewer-bot`) whose PAT can only read code and comment on PRs. The Skill deliberately tells it to `pip install` and run tests. Network policy denies PyPI, so the agent notes the block and falls back to static review. That denial (visible in `sbx policy log`) is the point of the demo, so **do not remove that Skill step**.

The audience should see Docker machinery (kit files, policy checks, the DENY log entry, a bot-authored comment with a traceability footer), not Claude output.

## Layout

- `kits/developer/` and `kits/reviewer/`: v2 sandbox kits (`spec.yaml` with `extends: claude`, plus `files/home/...` placed at `/home/agent/`).
  - Reviewer files: `reviewer-loop.sh`, `review-prompt.md`, and `.claude/skills/code-review/SKILL.md`.
  - Developer files: `.claude/skills/implementer/SKILL.md`.
- `sbx-demo-app/`: the contents of the **separate** GitHub repo `<owner>/sbx-demo-app` (small Python service plus pytest, with `specs/001-discount-codes.md`). It is staged here only for authoring. It must be published as its own repo and cloned to `~/src/sbx-demo-app`, which is what gets bind-mounted into the developer sandbox. It has its own `CLAUDE.md` meant for that repo.
- `RUNBOOK-NOTES.md`: the section 6 checklist split into verified and to-run-on-the-Mac, plus deviations from the spec.

## Architecture points that span files

- The reviewer's entrypoint is `reviewer-loop.sh` (set via `sandbox.entrypoint` in `spec.yaml`). It clones each PR to `/home/agent/workspace/pr-N`, runs `claude -p` against `review-prompt.md` (with `{{PR}}`/`{{OUT}}` substituted), then **the script, not the agent**, appends the traceability footer and posts via `gh pr comment --body-file`.
  - State is kept in `/home/agent/state/handled.txt`, and a PR is recorded only after its comment succeeds.
  - Use `set -u`, not `set -e`, so one failed review doesn't kill the loop.
  - The footer text is specified exactly in spec section 4.5; keep its last line ("cannot push, approve, or merge").
- Lockdown is layered:
  - The PAT scope limits what the token can do.
  - Kit `deny` rules on the registries survive even under org governance, where kit `allow` rules are inactive.
  - Branch protection on `main` requires one approving review.
- Credentials: the sandbox only ever sees a sentinel, and the host proxy injects the real header.
  - **Never set a global `github` secret.** Use sandbox-scoped ones (`--sandbox developer`, `--sandbox reviewer`), because a global one would silently hand the reviewer the user's full token if the scoped one failed to apply. Verify with `sbx secret ls`.
  - Claude Code auth is `ANTHROPIC_API_KEY` via `sbx secret set anthropic`. Proxy-managed OAuth is not supported for third-party kits.
  - Third-party kits need bindings in `~/.config/sbx/credentials.yaml`. Without one, a non-interactive run starts with the credential withheld and only prints a warning.
- `extends: claude` inheriting the built-in `anthropic`/`github` credential declarations is inferred, not confirmed. If the reviewer gets no GitHub token, add an explicit `credentials:` block to both kits.

## Commands

Every `sbx` invocation must match spec section 9. Do not invent flags, and trust `sbx ... --help` over the spec if they disagree (then record the difference). If a documented command behaves differently, stop, show the actual output, and propose the smallest workaround.

```bash
sbx kit validate ./kits/developer            # also ./kits/reviewer; all `sbx kit` commands are experimental
sbx run --name reviewer --skills=off -e REPO=<owner>/sbx-demo-app -e POLL_SECONDS=30 ./kits/reviewer
sbx run --name developer --skills=off ./kits/developer ~/src/sbx-demo-app -- "Implement specs/001-discount-codes.md using the implementer skill."
sbx exec reviewer gh auth status             # should show acme-reviewer-bot
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
- Be honest about the identity story in anything demo-facing: both sandboxes run under the user's **Docker** identity. Only the reviewer's **GitHub** identity is distinct (a strict subset of permissions). Don't claim a distinct Docker agent identity, and don't promise audit `.jsonl` records unless the org has AI Governance with enforced policy (check `~/Library/Logs/com.docker.sandboxes/sandboxes/auditkit/`).
- Spec section 8 lists the scope-cut order if time runs short. If the in-sandbox loop fails because the runtime needs the agent binary as PID 1, fall back to a host-side loop using `sbx exec`.
