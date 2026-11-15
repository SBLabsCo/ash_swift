# The ship-ticket delivery loop

`ship-ticket` is a saved Claude Code workflow ([`.claude/workflows/ship-ticket.js`](../../.claude/workflows/ship-ticket.js))
that drives `ready-for-agent` issues to **merge-ready** PRs on a maintainer's machine. It never merges:
merge is the human gate. It's ported from SBLabsCo/SwingClips, minus that app's visual-evidence and
client-compatibility stages.

It runs locally in an interactive Claude Code session, unlike the GitHub-side `claude-implement.yml`
and `claude-address-review.yml` ([ai-automation.md](ai-automation.md)). Both paths still work. The local loop
adds pre-PR review lenses and a deterministic drive-to-clean loop.

## Running it

From a Claude Code session in this repo, ask it to run the workflow by name:

```
ship-ticket {issues: [91, 92], concurrency?: 3, answers?: {"91": "answer to its BLOCKED question"}, main?: "<path to this checkout>"}
```

`main` defaults to the maintainer's checkout path baked into the script; pass it on any other machine.

## What it does, per ticket

1. **Preflight** — `bin/orchestration-fresh` (once per run): refuses to start if the main checkout's
   `.claude/workflows`, `.claude/agents` or `.claude/skills` differ from `origin/main`, because those
   are read from the working tree. Then `bin/ticket-preflight <n> --check-only`: the issue is open and labelled
   `ready-for-agent`, and has no open PR.
2. **Implement** — the [`implementer`](../../.claude/agents/implementer.md) agent, in its own worktree under
   `.claude/worktrees/`, commits and stops at READY (or BLOCKED with one question).
3. **Review** — read-only lenses in parallel on the branch, before any PR exists. [`reviewer`](../../.claude/agents/reviewer.md),
   [`refactorer`](../../.claude/agents/refactorer.md) and [`security`](../../.claude/agents/security.md) run on every diff;
   [`architect`](../../.claude/agents/architect.md) runs when the diff touches `lib/`, `Sources/`, `test/` or `Tests/`.
   Docs-only diffs skip review.
4. **Address** — every finding is fixed or declined with a rationale (fix even nits). A fixed must-fix gets one re-review.
5. **Open PR** — `bin/pr-open <n> --summary-file <f>` writes the body (summary, `Closes #n`, declined findings, attribution) and pushes.
6. **Drive** — `bin/pr-wait <pr>` loops until CI is green, the review Action's verdict is clean, and no review
   threads are unresolved. It rebases on conflict and runs up to 4 fix passes before escalating. `bin/pr-threads` lists and resolves threads.
7. **Run record** — `bin/pr-record` posts the outcome as a hidden comment on the PR.

Outcomes: `merge-ready`, `blocked` (re-run with `answers`), `refused` (preflight said no), `escalated` (needs a human), `failed`.

## After merge

```bash
bin/pr-record <pr> --read | jq .followups > "$TMPDIR/followups-<pr>.json"
bin/after-merge <pr> --followups "$TMPDIR/followups-<pr>.json"
```

`bin/after-merge` removes the ticket's worktree and branch, files the review lenses' follow-up issues
(only when handed the file; it reads it twice, so use a real file, not `<(...)`), and fast-forwards the
main checkout. It fast-forwards only when the checkout is on `main` and clean, so in-progress work is never disturbed.

## Contracts

**Review verdict footer.** After a successful run, `.github/workflows/claude-review.yml` posts a comment
whose whole body is `<!-- ash-swift-review-verdict: {"v":1,"sha":"<head>","must_fix":0,"should_fix":0,"nit":0,"clean":true} -->`.
The workflow posts it, not the model, because the action's sanitizer strips HTML comments from model-written text.
`bin/pr-wait` (`pr_wait_footer` in `bin/pr-wait-lib.sh`) is its one parser. It counts only `v == 1` footers
from `github-actions[bot]` that name the current head. No footer for the head means `not_run`, which escalates.
A PR that edits the review workflow itself may get no verdict.

**Run record.** The comment's whole body is one line, `<!-- ash-swift-run-record: {...} -->`, holding single-line JSON
with `v == 1`, `issue`, `pr`, `outcome`, `reason`, `verdicts`, `findings` (id, source, severity, where, outcome),
`declined`, `followups`, `blocked`, `rounds` and `action_verdicts`. `bin/pr-record <pr> --file` posts it, or updates it in place
on a re-run. `--read` returns the latest one from an OWNER, MEMBER or COLLABORATOR. Change the format only with a `v` bump.

## Tests

Each `bin/` script has a `bin/<name>.test.sh`; run them one at a time from the repo root (`bash bin/pr-wait.test.sh`).
They need `bash` ≥ 5, `jq` and `git`; none touch the network.
