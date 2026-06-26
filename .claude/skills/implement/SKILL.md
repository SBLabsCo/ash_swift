---
name: implement
description: "Implement a piece of work based on a PRD or set of issues."
disable-model-invocation: true
---

Implement the work described by the user in the PRD or issues.

Use /tdd where possible, at pre-agreed seams.

Run typechecking regularly, single test files regularly, and the full test suite once at the end.

Once done, review your own diff for correctness, simplification, and scope creep before committing. (The repo's automated PR review runs separately once you open the PR.)

When a review — yours or the automated one — flags something, resolve it: fix it, or push back with explicit rationale and get agreement. Don't silently drop a flagged test or coverage gap; a defensive branch is often where a neighboring bug hides.

Keep the docs in sync with your change, in the same PR. If the work changes anything the docs assert — README features/status/roadmap, public API or usage examples, CONTEXT.md domain vocabulary, or an ADR/PRD's stated scope — update those docs too. A shipped feature still listed as "planned"/"next"/"in progress" in the README is a doc bug, not a follow-up. Any example code you add or touch must actually compile against the generated client. When in doubt, grep the docs for the terms your change affects and reconcile each hit.

Commit your work to the current branch.
