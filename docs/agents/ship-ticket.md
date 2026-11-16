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
7. **Run record** — `bin/pr-record` posts the outcome as a hidden comment on the PR. Each finding in it keeps a
   one-line `problem` and a `category`, which the [findings retro](#the-findings-retro) reads.

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
with `v == 2`, `issue`, `pr`, `outcome`, `reason`, `verdicts`, `findings`, `declined`, `followups`, `blocked`, `rounds`
and `action_verdicts`. Each finding carries `id`, `source` (the lens), `severity`, `where`, `outcome` (`fixed`, `declined`
or `open`), `problem` (the lens's problem as one line, clipped to 240 characters) and `category` (a kebab-case slug from
[finding-categories.md](finding-categories.md), `uncategorized` when the lens gave none). The full problem and fix text
stay in the workflow's own result. `bin/pr-record <pr> --file` posts the record, or updates it in place on a re-run.
`--read` returns the latest one from an OWNER, MEMBER or COLLABORATOR.

- **Versions.** Readers accept every version still on a PR (`v` 1 and 2). A `v` 1 record is the same minus each finding's
  `problem` and `category`. `bin/pr-record --file` writes only the current version (`v` 2), so a stale workflow cannot post
  an old shape. A field an old reader can do without arrives additively, with no bump. A field a reader must be able to
  rely on (as the retro relies on `category`) needs a bump, and the parser (`pr_record_matching` in `bin/pr-record-lib.sh`)
  keeps accepting the old version.
- **Backfill.** All 14 records on #93–#121 were written as `v` 1 and rewritten to `v` 2 in place on 2026-11-15, from the
  workflow's local run results (the only place the finding text survived), so the first retro had data.

## The findings retro

The lenses catch the same kinds of mistake PR after PR, and each catch costs a review round. The retro feeds the lesson
back to the implementer.

- **`bin/findings-retro`** (read-only; JSON contract in its header) reads the run records of the PRs merged since the last
  retro and groups their findings by `category` and lens. A category raised on at least two PRs is *recurring*. It also
  lists categories declined on at least two PRs, and the still-open follow-up issues those PRs filed.
- **The `findings-retro` skill** ([`.claude/skills/findings-retro/SKILL.md`](../../.claude/skills/findings-retro/SKILL.md))
  is the judgment half. For each recurring category it edits what the implementer reads at the moment of that mistake:
  `CLAUDE.md`'s checklist, [`.claude/agents/implementer.md`](../../.claude/agents/implementer.md), or a lens's own checklist
  when the lens catches the mistake unevenly. It folds in open follow-ups that propose guidance lines, and opens **one** PR
  titled `Findings retro: <window>`. Recurring *declines* are reported in that PR but never edited for: they say more about a
  lens's calibration than about the implementer, and changing a lens is the maintainer's call. The PR never self-merges.
- **The title marks the window.** The next retro reads from the newest merged PR whose title starts with `Findings retro`.
  A retro PR's title must start with it, and no other PR's title may.
- **Cadence: on demand, never scheduled.** Run it after a batch of tickets has merged or a milestone closes, so the next
  tickets start with the lessons, or when a review keeps raising something that feels familiar. A retro needs a body of
  merged work, not a fixed interval, and one with nothing new to read is noise.
- **Categories are a shared vocabulary** ([finding-categories.md](finding-categories.md)). The lenses take slugs from it and
  coin a new one only when none fits. The retro adds the slugs that earned a place and folds drifting synonyms together,
  because a recurring mistake split across two slugs looks rare twice.

## Tests

Each `bin/` script has a `bin/<name>.test.sh`; run them one at a time from the repo root (`bash bin/pr-wait.test.sh`).
`bin/ship-ticket.test.sh` covers the workflow itself: it lifts the run-record code out of `ship-ticket.js` and checks
with `node` that the record it writes is one `bin/pr-record` accepts. They need `bash` ≥ 5, `jq` and `git` (and `node`
for that one); none touch the network.
