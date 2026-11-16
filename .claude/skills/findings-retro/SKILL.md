---
name: findings-retro
description: "Turn the pre-PR review findings that keep recurring across merged ash_swift PRs into guidance the implementer reads, as one PR. Reads the ship-ticket run records with bin/findings-retro, proposes an edit per recurring category, folds in open guidance follow-ups, reports recurring declines without editing for them. Use after a batch of tickets or a milestone, or when asked for a findings retro."
disable-model-invocation: true
---

# Findings retro

The `ship-ticket` lenses catch the same kinds of mistake PR after PR: a moduledoc that no longer matches the Reader, a test harness rebuilt beside one that exists, a redundant test, one IR decision made in two places. Each catch costs a review round. This retro closes that loop. It reads what the lenses found and, where a mistake recurs, puts the lesson where the **implementer** reads it before writing code, so the next ticket doesn't make it. How and when it runs is in [docs/agents/ship-ticket.md](../../../docs/agents/ship-ticket.md#the-findings-retro); this file is the how-to.

The output is **one PR** titled `Findings retro: <window>`. That title prefix is load-bearing: `bin/findings-retro`'s default window starts at the newest merged PR whose title starts with `Findings retro`. No other PR may use the prefix. Never merge the PR; merging is the maintainer's job.

## 1. Gather

Work in a fresh worktree branched from `origin/main`, never the maintainer's checkout. Then:

```bash
bin/findings-retro > "$TMPDIR/retro.json"           # PRs merged since the last retro merged
```

`--last <n>` (the newest n merged PRs carrying a record), `--prs 106,107,111` and `--min-prs <n>` (default 2) change the window and the threshold. The header of `bin/findings-retro` documents the JSON. What you use:

- `categories[]` with `recurring: true`: raised on at least `--min-prs` distinct PRs. Each carries its `prs`, the `lenses` that raised it, `outcomes`, and every finding's one-line `problem` and `where`.
- `declined_recurring[]`: categories that were *declined* on several PRs.
- `open_followup_issues[]`: follow-ups those PRs filed (via `bin/after-merge --followups`) that are still open.
- `uncategorized`: v1 records (before categories existed) and findings a lens left uncategorised. They are only counted. Say so in the PR body when they are a large share of the window.

## 2. One edit per recurring category

Read every `problem` in the category before writing. If the problems disagree about what the mistake is, open one or two `where` locations on `main`. Then:

1. **Grep the guidance first.** If a line already covers the mistake, it still recurred, so the line is in the wrong place, too vague, or buried. Sharpen it or move it to where the implementer reads it. Don't add a second line.
2. **Pick the file the implementer reads at the moment of the mistake:**

   | The mistake is about | Edit |
   |---|---|
   | The codebase's rules, which every implementer must follow (the local `implementer` agent and the GitHub `claude-implement` Action alike): the Reader → IR → Emitter seams, tests, the test harness, docs that must match code | `CLAUDE.md`, in its checklist section (create one titled `## Checklist before committing` the first time) |
   | The ship-ticket implementer's own process: what to read first, the finish line, the report | `.claude/agents/implementer.md` ("What this repo holds you to" or "Finish line") |
   | A lens catching it unevenly (one lens on some PRs, a different lens on others) | that lens's own checklist in `.claude/agents/<lens>.md`, in addition to the implementer edit |

   `docs/agents/lessons.md` is not a retro target. It holds narrative wire-shape and codegen traps under its own bar, and a checklist line belongs in a checklist.
3. **Write one checkable line**: an imperative an implementer can tick or fail, naming the API or file involved. For example: "When you change what the Reader puts in an IR key, grep `reader.ex`'s moduledoc, `README.md` and `docs/agents/lessons.md` for the key and fix each claim." Write no essay and no history: short sentences, one idea per line, the same terms the file already uses.
4. **Skip a category** whose findings don't share a preventable cause, such as two unrelated `unhandled-edge-case`s. List it as skipped in the PR body with the reason. A category is a hint, not an order.

## 3. Fold in the open follow-ups

For each of `open_followup_issues` whose body proposes a guidance or checklist line, make that edit here, merged with any category edit that covers the same ground, and put `Closes #<n>` in the PR body. Leave other follow-ups (refactors, new tests) alone: they are tickets, not lessons.

## 4. Recurring declines: report only

A category declined on several PRs is a signal about the **lens**, not the implementer. The lens may be miscalibrated, or may be asking for something the house rules don't want. **Make no edit for these.** List each in the PR body with the lens, the PRs, the decline rationales, and your read: a miscalibrated lens, or a real gap the implementer keeps arguing away. Changing a lens is the maintainer's call. Give it its own issue if they want one.

## 5. The vocabulary

If records carry categories that `docs/agents/finding-categories.md` lacks, add the ones that earned a place. If two slugs name one mistake, fold one into the other in the doc so later records converge. A split category hides recurrence.

## 6. Open the PR

Open one PR titled `Findings retro: <window>`, for example `Findings retro: #93–#119`. The body carries:

- the window (`window` from the JSON) and how many records and findings it read;
- a table with one row per recurring category: category, count of PRs (with links), lenses, and the edit made (file and line), or "skipped: why";
- `Closes #n` for each follow-up folded in;
- "Recurring declines (no edit)" from step 4;
- the share of the window that was `uncategorized`.

Open it with `gh pr create` (the PR closes no ticket, so `bin/pr-open` does not apply), then drive it with `bin/pr-wait <pr>` until it is green and the review is clean, fixing what the review raises. The PR is docs-only, so the review Action is its only reviewer. If nothing recurs, open no PR and say so.
