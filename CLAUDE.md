# ash_swift

A Swift port of [ash_typescript](https://github.com/ash-project/ash_typescript).

## Agent skills

### Issue tracker

Issues live in the repo's GitHub Issues (via the `gh` CLI); external PRs are also a triage surface. See `docs/agents/issue-tracker.md`.

### Triage labels

Default vocabulary: needs-triage, needs-info, ready-for-agent, ready-for-human, wontfix. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: one CONTEXT.md + docs/adr/ at the repo root. See `docs/agents/domain.md`.

### CI & AI automation

GitHub Actions run CI (Elixir + Swift) and Claude-driven review, triage, and issue implementation. See `docs/agents/ai-automation.md`.

### Local delivery loop (ship-ticket)

The saved `ship-ticket` workflow (`.claude/workflows/ship-ticket.js`; run by name with `{issues: [...]}`) drives `ready-for-agent` issues to merge-ready PRs locally: implementer → pre-PR review lenses (`.claude/agents/`) → `bin/pr-open` → `bin/pr-wait` loop. It never merges. See `docs/agents/ship-ticket.md`.

### Findings retro

On demand (after a batch of tickets or a milestone, never scheduled), the `findings-retro` skill reads the ship-ticket run records with `bin/findings-retro` and turns review-finding categories that recur across merged PRs into guidance the implementer reads, as one `Findings retro: <window>` PR. No other PR title may start with `Findings retro`. Categories come from `docs/agents/finding-categories.md`. See `docs/agents/ship-ticket.md`.

### Lessons from earlier runs

Non-obvious patterns earlier implement / address-review runs got wrong are captured in `docs/agents/lessons.md`. Implement and `/address-review` prompts read it as context. Append to it only when you've hit a non-obvious, recurring pattern that isn't already there.
