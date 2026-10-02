# Iteration 2 — Requirements from the abstract

Input to the iteration 2 spec. Derived from `Meet_the_Agentic_Team.pdf` against what iteration 1 (tag `step-01`) actually delivers. Each requirement says what the abstract promises, what exists today, and the smallest thing that makes the promise true on stage. Status: **have** / **partial** / **missing**.

## What the abstract promises

1. Agents with defined roles, persistent instructions, isolated environments, and clear handoffs.
2. Three agents on one project: an implementer, an independent reviewer, and a coordinator.
3. The team communicates through Slack.
4. Git, Skills and specifications are the shared knowledge that survives individual conversations.
5. Seven techniques: Skills onboarding; specs and acceptance criteria; architectural boundaries enforced by tests; mutation testing; different models for implementation and review; safe environments for YOLO mode; feedback loops that let agents find and fix their own mistakes.
6. Patterns that apply to Claude Code, Codex and other coding agents.

## What iteration 1 delivers

Two sandboxes (developer, reviewer) built from kits, same agent (Claude Code), different network policy. Implementer and code-review Skills. One spec (`001-discount-codes`) with acceptance criteria. Reviewer polls GitHub, reviews under a versioned Skill, posts a comment with a traceability footer. PyPI denied for the reviewer; the DENY is visible in `sbx policy log`. Both sandboxes run under Jeremy's GitHub account; the bot identity, GitHub org, and branch protection are deferred. No Slack, no coordinator, no architecture tests, no mutation testing, one model, no loop back from review to implementation.

## Requirements

### A. Roles and handoffs

- **A1 (missing) Coordinator agent.** A third sandbox (`coordinator`) with its own kit and Skill. Receives a feature request, turns it into (or validates) a spec with acceptance criteria, hands the spec to the implementer, watches for the PR, relays the review verdict, and decides when the work is done or needs another round. It never writes application code.
- **A2 (partial) Explicit handoff contracts.** Each handoff is a file or GitHub object, not a chat message: request → `specs/NNN-*.md`; spec → PR whose body links the spec; PR → review comment with `Blocking`/`Suggestions`/`Environment notes`; review → either a follow-up commit on the PR branch or a "ready" signal. The spec should define these as the interfaces between roles.
- **A3 (have) Role definition lives in the kit**, not the prompt: `agentInstructions` + Skill per role. Keep. Add the coordinator kit in the same shape so the three `spec.yaml` files can be shown side by side.
- **A4 (missing) Memory that survives conversations.** The abstract's "prone to forgetting" line needs a visible answer: show that a fresh sandbox with the same kit behaves the same (kit = persistent instructions), and that project state lives in Git (specs, PR history) and Slack (the thread), not in any one agent's context. Candidate demo beat: `sbx rm` the implementer and recreate it mid-demo.

### B. Communication

- **B1 (missing) Slack as the team channel.** One channel (e.g. `#agentic-team`) where: the coordinator announces a spec was accepted and assigned; the implementer (or coordinator on its behalf) posts the PR link; the reviewer posts its verdict summary with a link to the full comment; the coordinator posts "merged" / "needs changes". Humans read; agents write. Minimal mechanism: a Slack app with a bot token, injected as a sandbox-scoped secret through the proxy like the GitHub token, `api.slack.com` on each kit's allow list.
- **B2 (optional) Slack as the request intake.** The coordinator polls the channel for a request (e.g. a message starting with `feature:`) and turns it into a spec. This is the "clear handoff from human to team" opener. Needs `channels:history` scope and a poll loop like the reviewer's. If time is short, the request is typed as the coordinator's launch prompt instead and B1 alone stands.
- **B3 (requirement on B1) Attribution in Slack.** Every agent post ends with the same traceability line the PR footer uses (sandbox, Skill version, model, triggered-by), so Slack is a second audit surface, consistent with GitHub.

### C. Shared knowledge

- **C1 (partial) Specs with acceptance criteria.** The demo app is being rebuilt in Java/Quarkus (see I1), so the specs are rewritten for it: `001` is the seed feature used to prove the pipeline, `002` is the live demo feature and is designed to exercise the architecture boundary (D1) and give mutation testing (D2) something to find.
- **C2 (have) Skills per role, versioned.** Bump `code-review` to 1.1.0 when its steps change (mutation testing, architecture test). Add `implementer` version and print it in the PR body.
- **C3 (partial) Repo-level CLAUDE.md in `sbx-demo-app`** should state the architecture rules in one paragraph so both the implementer and the reviewer read the same boundary definition.

### D. Quality gates (the "techniques" bullets)

- **D1 (missing) Architectural boundaries enforced by tests.** ArchUnit tests in the Quarkus app: domain package has no dependency on the REST, persistence or Qute layers; REST resources do not touch Panache entities directly except through a service; no cycles between packages. Plant the trap: spec 002 is easiest to implement by violating a boundary; a good implementer doesn't, and the test Skill (D5) catches it if it does.
- **D2 (missing) Mutation testing.** PIT (`pitest-maven` with the JUnit 5 plugin) scoped to the domain package, with a mutation-score threshold that fails the build. Plant the trap: 001 ships with weak tests by design; "tests pass" is true and the mutation score is bad. Runs in the developer image via the test Skill (D5), not in the reviewer: the reviewer stays static and stays denied.
- **D5 (missing) Test Skill in the developer kit.** A `verify` Skill that the implementer must run before pushing: `mvn -q verify` (unit + Quarkus tests with Dev Services), ArchUnit, PIT with threshold. Its output (test count, ArchUnit result, mutation score) goes into the PR body so the reviewer and the audience can read it. This is feedback loop (i) made mandatory and visible.
- **D3 (partial) Safe environments for YOLO mode.** Already true (`--dangerously-skip-permissions` inside a sandbox with a deny-all baseline). Make it a stated beat: show the flag, then show the policy that makes it safe. No new build work.
- **D4 (missing) Feedback loops.** Three loops, in increasing ambition: (i) implementer runs the tests and architecture check before pushing and fixes failures itself; (ii) reviewer's `Blocking` list is picked up by the implementer, which pushes a fix commit on the same branch, and the reviewer re-reviews the new SHA (the loop currently tracks PR numbers; it must track head SHAs); (iii) mutation score below threshold is itself a `Blocking` finding. Loop (ii) is the one the audience should see live; it also requires the coordinator or the reviewer to post a signal the implementer watches.

### E. Model diversity

- **E1 (tabled 2026-10-02) Different models for implementation and review.** Decision: the reviewer becomes a Codex agent (`sbx` built-in `codex`), matching the abstract's "Claude Code, Codex, and other coding agents". Tabled until Slack, the Quarkus app and the coordinator work; until then the footer's model field is the honest statement of what ran. Interim cheap variant if time allows: a different Claude model for the reviewer via `ANTHROPIC_MODEL`.

### F. Identity and delegation (carried from iteration 1)

- **F1 (deferred) Distinct reviewer GitHub identity**: free org, machine user, fine-grained PAT (Contents read, PRs read/write), `REVIEWER_LOCKED_DOWN=1`, push probe → 403. Steps are already written at the end of `RUNBOOK-NOTES.md`.
- **F2 (deferred) Branch protection on `main`** requiring one approving review; only meaningful once F1 exists.
- **F3 (stretch) Expiring, per-request tokens** (GitHub App installation tokens) for the delegation-with-expiry beat the iteration 1 runbook promised for "iteration 2". Candidate for iteration 3 if F1/F2 land late.
- **F4 (requirement) Coordinator identity.** The coordinator needs the broadest GitHub scope (merge) and the Slack token; its kit should be the one with the most privilege and the narrowest network allow list, to make the point that privilege and reach are separate dials.

### G. Observability and the demo story

- **G1 (have) `sbx policy log` DENY beat.** Keep. Extend the deny list to whatever the new tools would otherwise reach.
- **G2 (requirement) One traceability format across three surfaces**: PR comment footer, Slack post footer, reviewer/coordinator loop logs. Same fields, same order.
- **G3 (requirement) Reset in under two minutes.** Three sandboxes, Slack history, PR branches and `handled.txt` all need a documented reset; the iteration 1 lesson (scoped secrets die with the sandbox) means the reset script must re-set secrets.

### H. Environment and kits

- **H1 (decision pending) Kit schema.** The developer image now needs JDK 25 and Maven, which the built-in `claude` image does not carry. Options: v2 mixin with `setup.install[]` installing a JDK at first start (slow, network-dependent, but keeps OAuth via the built-in agent), or a v3 Dockerfile kit with JDK and Maven baked in (fast, pinned, but iteration 1 showed OAuth is unsupported for kits that replace the agent, so it would need an API key or the mixin-on-built-in pattern re-verified for v3). Resolve in the Quarkus spike (see plan).
- **H2 (decided 2026-10-02) Tests and mutation testing run in the developer image**, via the `verify` Skill (D5). The reviewer stays static. Its deny list changes from PyPI to Maven Central (`repo.maven.apache.org`, `repo1.maven.org`) plus Docker Hub, so the DENY beat becomes `mvn` failing to resolve dependencies.
- **H4 (requirement) Docker inside the developer sandbox.** Quarkus Dev Services starts PostgreSQL 17 through Testcontainers, which needs a reachable Docker daemon and Docker Hub access from inside the sandbox. Verify `sbx exec developer docker ps` and the image pull before anything else in the Quarkus spike; if unavailable, the fallback is a plain `postgres:17` container started by `setup.startup[]` with `%test` datasource properties pointing at it.
- **H3 (requirement) Three kits side by side** with visibly different `permissions.network` and credentials blocks, which is the opening slide of the demo.

### I. Demo application (decided 2026-10-02)

- **I1 Stack.** Quarkus 3.31.x on Java 25; PostgreSQL 17 through Quarkus Dev Services in dev and test; Hibernate ORM with Panache; Qute templates with htmx for interactivity; SmallRye Health and Micrometer; Maven build. The REST client contract is generated from the OpenAPI document (Quarkus OpenAPI Generator), not hand-written, so a spec can say "add an endpoint" and the client follows from the contract.
- **I2 Shape.** Based on https://github.com/jeremyrdavis/thoughtsapp-monolith
- **I3 Repo.** Replaces `sbx-demo-app` on GitHub (new repo or force-replaced `main`), cloned to `~/src/sbx-demo-app` as before. The Python version stays reachable at tag `step-01` of this repo.
- **I4 Developer kit.** Allow list grows to Maven Central, Docker Hub (`registry-1.docker.io`, `auth.docker.io`, `production.cloudflare.docker.com`) and whatever the OpenAPI generator fetches; the kit provides JDK 25, Maven, and the `verify` Skill.

## Suggested demo arc (for the spec's section 7)

1. Three kits side by side: role, reach, privilege.
2. Human prompts the developer sandbox to pick up an issue in GitHub and address it.
3. Developer sandbox implements, runs the `verify` Skill (tests with Dev Services, ArchUnit, PIT), pushes, opens the PR with the verify summary in the body; Slack gets the link.
4. Coordinator picks up the PR link from Slack and assigns it to a reviewer by replying to the Slack thread.
5. Reviewer picks up the PR; `mvn` cannot reach Maven Central (DENY in `sbx policy log`); it reviews the PR, adds comments, and replies to the Slack thread. 
6. Human reviews the comments and merges the PR.

## Non-goals for iteration 2 (proposed)

Cloud sandboxes, org policy authoring, CI runner outside the sandboxes, more than one Slack channel, a web UI, any agent other than the three roles.

## Decisions made 2026-10-02

1. **Slack first.** Final state: coordinator, developer and reviewer all read from and write to Slack. Workspace: `mobyai.slack.com`. Next spike: Slack notifications from the existing developer and reviewer kits (B1), before any coordinator work. Reading from Slack (B2) comes with the coordinator.
2. **Codex reviewer**, tabled until the rest works (E1).
3. **Java/Quarkus app** per I1.
4. **Tests, ArchUnit and PIT run in the developer image** through a Skill in the developer kit (D5, H2).
5. **Identity work (F1–F3) stays deferred** until everything else works.
6. **Slot: Tuesday 2026-10-06, 18:15, 45 minutes** including talk. Assume 15–20 minutes of live demo.

## Plan to Tuesday (four working days) and scope-cut order

Build in this order; each spike ends with a tagged, runnable state so the demo can be given from whichever tag is clean on Tuesday.

1. **Spike 1 — Slack notifications (`step-02`).** Slack app in `mobyai.slack.com` with a bot token (`chat:write`, plus `channels:history` reserved for the coordinator later); channel `#agentic-team`. Token delivered as a sandbox-scoped secret and injected by the proxy; `slack.com` on both allow lists. Reviewer loop posts pickup and verdict; developer posts the PR link (from the implementer Skill, or from a host-side hook if the agent cannot be relied on to post). Same footer as the PR comment. Unknown to resolve first: whether a v2 mixin may declare a custom `credentials[]` service so the token stays a sentinel inside the sandbox; fallback is `-e SLACK_BOT_TOKEN` with the honest caveat that this token is visible in the sandbox.
2. **Spike 2 — Quarkus app and developer `verify` Skill (`step-03`).** New app per I1/I2, ArchUnit and PIT wired, specs 001/002 rewritten, developer kit with JDK/Maven and the Skill, reviewer deny list moved to Maven Central. Run the iteration 1 flow end to end on the new stack. Biggest risk: Docker-in-sandbox for Dev Services (H4) and image/kit build time (H1).
3. **Spike 3 — Coordinator (`step-04`).** Third kit, reads a request from Slack, writes the spec, assigns, relays verdict, closes the loop; implementer picks up `Blocking` and pushes a fix; reviewer tracks head SHAs.
4. Codex reviewer, then identity (F1–F3), only if 1–3 are clean by Monday night.

Scope-cut order if Tuesday arrives early: drop 4; demo the coordinator as a recording and run spikes 1–2 live; drop PIT and keep ArchUnit; fall back to the Python app at `step-01` with Slack bolted on.
