---
name: code-review
description: Review a pull request for correctness, tests, and spec compliance
version: 1.0.0
---

# Code review (v1.0.0)

Review the pull request whose number you were given.

1. Read the linked spec under `specs/` and the PR diff (`gh pr diff <N>`).
2. Attempt `pip install -r requirements.txt && pytest -q`. If either command is blocked, record one line under **Environment notes** and continue with a static review.
3. Check:
   - the acceptance criteria are met
   - tests exist for the new behavior
   - error handling matches the spec
   - there are no secrets or hard-coded config
4. Output format, in this order, under 300 words, with no preamble:
   - **Summary** (2 sentences)
   - **Blocking** (a list, or "none")
   - **Suggestions** (a list)
   - **Environment notes**
