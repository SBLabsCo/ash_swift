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

## Checklist before committing

Every implementer (the local `implementer` agent and the `claude-implement` Action) walks this against its diff. The pre-PR review kept catching these; the `findings-retro` skill (#125) maintains the list.

- **Docs match the code.** For every function, IR key or value whose behaviour you changed, grep `lib/`, `test/`, `README.md` and `docs/agents/lessons.md` for its name and fix each comment, moduledoc (above all the IR key list in `reader.ex`) and test comment it makes false or only partly true. When a comment gives a reason or cites an ADR or issue, check that the source says so.
- **One decision, one place.** Make each IR decision once, in the Reader. The Emitter and `Contract` dispatch on an IR key the same way, with explicit guards rather than clause order.
- **No pass-through layers.** Don't add a type, helper, wrapper or alias that only forwards a call or copies fields across. If deleting it would lose nothing, don't add it.
- **Reuse the test harness.** Before writing test setup (a temp dir, a stub or capturing transport, a consumer package), look in `test/support/` and the neighbouring `describe`'s `setup`. Swift-running tests use `SwiftConsumer.shared_package/0` and `run_swift_test!/2`, with `stubRpc` / `capturingRpc` from `test/support/swift/StubTransport.swift`. Extend or extract a shared helper; never write a second copy.
- **Every new behaviour has a test that fails if it breaks.** That covers each new IR key, request body key and code branch. A change to a generated public signature is called from the consumer package (`test/support/swift/ConsumerCheck.swift`).
- **Test at the IR seam.** Pin a Reader classification in `test/ash_swift/codegen/reader_test.exs` against the IR (ADR-0010), not only by substring matches on rendered Swift. Pin Swift formatting in `test/ash_swift/codegen/emitter_test.exs`, which drives `Emitter.render_types/1` / `render_functions/1` over a hand-built IR; `codegen_test.exs` keeps only end-to-end smoke checks and the generate/stale_files tests.
- **No redundant tests.** Before adding a test, grep for one that already pins the behaviour. When a new test supersedes older ones, delete them in the same diff.
- **Every assertion can fail.** Don't `refute` a string that an earlier assertion already excludes, and don't assert on what setup always produces (for example `File.exists?` on a file the harness writes).
- **Names match bodies.** A test's name and its `describe` / `// MARK:` section say exactly what its body asserts, and the test names the cases it claims to cover.
