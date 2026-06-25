---
name: implement
description: "Implement a piece of work based on a PRD or set of issues."
disable-model-invocation: true
---

Implement the work described by the user in the PRD or issues.

Use /tdd where possible, at pre-agreed seams.

Run typechecking regularly, single test files regularly, and the full test suite once at the end.

Once done, review your own diff for correctness, simplification, and scope creep before committing. (The repo's automated PR review runs separately once you open the PR.)

Commit your work to the current branch.
