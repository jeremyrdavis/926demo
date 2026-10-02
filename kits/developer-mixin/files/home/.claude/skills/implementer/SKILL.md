---
name: implementer
description: Implement a spec from specs/ and open a PR, announcing start and PR link in Slack
version: 1.1.0
---

# Implementer (v1.1.0)

Implement the spec you were pointed at, then open a PR. The team channel is Slack; use only the two scripts below to talk to it, never anything else.

0. If you were not given a spec path, run `bash ~/bin/slack-read.sh --latest-prefix 'developer:'` and treat its output as your task. If it prints nothing, say "no task found in Slack" and stop.
1. Read the spec under `specs/`. Work only from it.
2. Post `bash ~/bin/slack-post.sh --skill implementer --skill-version 1.1.0 "Starting <spec path>."`
3. Create a branch from `main` named `feat/<spec-id>`, where `<spec-id>` is the spec's filename without the `.md` extension (for `specs/001-discount-codes.md`, that is `feat/001-discount-codes`).
4. Implement the change. Be fast and minimal. Do not add tests; the reviewer owns test coverage.
5. Commit with a conventional message (for example `feat: add apply_discount`).
6. Push the branch and open a PR with `gh pr create`. The PR body must link the spec file.
7. Post `bash ~/bin/slack-post.sh --skill implementer --skill-version 1.1.0 "Opened <PR URL> for <spec path>."`
8. Print the PR URL as the last line of your output, then stop.
