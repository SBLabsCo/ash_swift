---
name: implement
description: "Implement a piece of work based on a PRD or set of issues."
disable-model-invocation: true
---

Implement the work described by the user in the PRD or issues.

**Step zero, before reading code or writing anything: start from a fresh base.** Run `git fetch origin`, then create your working branch from `origin/main` (`git switch -c issue-<n>-<slug> origin/main`). Do NOT start on whatever branch happens to be checked out, and do NOT assume the current branch is current. This repo squash-merges one PR per issue and moves fast, so a base even a day old is stale — branching from a stale base has produced conflicting, un-buildable PRs (issues #34, #70). This is the first thing you do, not a cleanup at the end.

Use /tdd where possible, at pre-agreed seams.

Run typechecking regularly, single test files regularly, and the full test suite once at the end.

Once done, review your own diff for correctness, simplification, and scope creep before committing. (The repo's automated PR review runs separately once you open the PR.)

When a review — yours or the automated one — flags something, resolve it: fix it, or push back with explicit rationale and get agreement. Don't silently drop a flagged test or coverage gap; a defensive branch is often where a neighboring bug hides.

Keep the docs in sync with your change, in the same PR. If the work changes anything the docs assert — README features/status/roadmap, public API or usage examples, CONTEXT.md domain vocabulary, or an ADR/PRD's stated scope — update those docs too. A shipped feature still listed as "planned"/"next"/"in progress" in the README is a doc bug, not a follow-up. Any example code you add or touch must actually compile against the generated client. When in doubt, grep the docs for the terms your change affects and reconcile each hit.

Commit your work to the branch you created from `origin/main` in step zero — never to `main`.
