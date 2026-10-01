---
name: implementer
description: Implement a spec from specs/ and open a PR
---

# Implementer

Implement the spec you were pointed at, then open a PR.

1. Read the spec under `specs/`. Work only from it.
2. Create a branch from `main` named `feat/<spec-id>`, where `<spec-id>` is the spec's filename without the `.md` extension (for `specs/001-discount-codes.md`, that is `feat/001-discount-codes`).
3. Implement the change. Be fast and minimal. Do not add tests; the reviewer owns test coverage.
4. Commit with a conventional message (for example `feat: add apply_discount`).
5. Push the branch and open a PR with `gh pr create`. The PR body must link the spec file.
6. Print the PR URL as the last line of your output, then stop.
