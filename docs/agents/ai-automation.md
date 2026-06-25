# AI in the development process

How this repo uses GitHub Actions for CI and for Claude-driven review, triage,
and implementation. Workflows live in `.github/workflows/`.

## Workflows at a glance

| Workflow | File | Trigger | What it does | Needs Claude? |
|----------|------|---------|--------------|---------------|
| CI | `ci.yml` | every PR / push to `main` | `mix format --check`, `mix compile --warnings-as-errors`, `mix test` (runs the Swift compile harness), `swift test` | no |
| Claude (@claude) | `claude.yml` | `@claude` in an issue/PR comment, review, or new issue | responds in context — answer, review, or make a change | yes |
| Claude PR review | `claude-review.yml` | PR opened / updated | independent inline review pass (comments only, never merges) | yes |
| Claude issue triage | `claude-triage.yml` | issue opened / reopened | applies a triage label per `triage-labels.md`; asks for info if underspecified | yes |
| Claude implement issue | `claude-implement.yml` | manual dispatch w/ issue number | implements the issue on a branch, runs the suite green, opens a PR | yes |
| Claude address review | `claude-address-review.yml` | `/address-review` comment on a PR | addresses the review feedback on the PR's own branch, runs the suite green, pushes | yes |

CI is independent and active immediately. The Claude workflows are **gated off**
until you complete setup, so they show up as skipped (not failed) and incur no
cost until you opt in.

## One-time setup (maintainer)

These steps require account/repo admin and can't be done from a code PR:

1. **Install the Claude GitHub App** on this repo (or the SBLabsCo org):
   <https://github.com/apps/claude>. This lets Claude read issues/PRs and post
   comments. The simplest path is to run `/install-github-app` from an
   interactive Claude Code session in this repo, which walks through it.
2. **Add the API key secret.** Repo → Settings → Secrets and variables →
   Actions → New repository secret: `ANTHROPIC_API_KEY`. (Alternatively use
   `claude_code_oauth_token` and update the `with:` inputs.)
3. **Flip the switch.** Same screen → Variables tab → New variable:
   `ENABLE_CLAUDE_AUTOMATION` = `true`. Every Claude workflow is gated on this,
   so this single variable turns them all on (set it back to `false` to pause).

## Using them

- **Ask Claude anything in-thread:** comment `@claude <request>` on an issue or
  PR. e.g. `@claude is this change wire-compatible with the TS client?`
- **Review:** happens automatically on each PR once enabled. To re-request,
  comment `@claude please re-review`.
- **Triage:** automatic on new issues. The label vocabulary is in
  `triage-labels.md`; the surfaces and rules are in `issue-tracker.md`.
- **Implement an issue:** Actions tab → "Claude implement issue" → Run workflow
  → enter the issue number (use only `ready-for-agent` issues). It opens a PR
  for review — it never merges.
- **Hand a PR's review off to an agent:** comment `/address-review` on the PR.
  An agent reads the review feedback, fixes it on the PR's own branch, runs the
  gates, and pushes — which re-triggers CI and the auto-review. This closes the
  loop: implement → review → `/address-review` → re-review → human merge.
  (`@claude` tag mode is read-only and can't edit code; this is the editing
  counterpart, scoped to a distinct phrase.)
  - **Steer it:** anything after the phrase becomes high-priority guidance on
    *how* to solve the findings — e.g. `/address-review use the complete Swift
    reserved-keyword set from the language reference, not just the example list`.
    Useful when an agent's first pass converges on a partial fix. The comment
    text is injected into the agent's prompt, so only trigger it yourself or from
    trusted collaborators (the action already restricts triggers to write
    access).

## Guardrails and caveats

- **The PR is the gate.** No workflow merges or approves. A human reviews every
  change; CI + the review pass inform that decision.
- **Cost.** The Claude workflows call the API and burn runner minutes (the
  implement workflow uses a macOS runner for the toolchains). `@claude`/review
  only run on real mentions/PRs; nothing runs while the gate variable is off.
- **Scope.** The implement prompt tells the agent to stay within one issue's
  acceptance criteria and not pull in later-milestone work — matching how we
  build issue-by-issue from the M1 PRD.
- **Verify the action interface.** `anthropics/claude-code-action@v1` inputs can
  change; if a workflow errors after enabling, check the action's current docs
  (`anthropic_api_key`, `prompt`, `claude_args`, `trigger_phrase`).
- **Permissions.** Each workflow requests only the scopes it needs. Triage is
  read + issues:write; review is read + pull-requests:write; implement needs
  contents:write to push its branch.
- **Skills are vendored in-repo.** The runner only has what's checked out — it
  cannot see your global `~/.claude/skills/`. Any skill the agent should use
  must live in `.claude/skills/` (committed) *and* `Skill` must be in that
  workflow's `--allowedTools`. We vendor `implement`, `tdd`, and `triage`; the
  implement/triage prompts invoke them by name. Re-sync from upstream by copying
  the skill folder in again.
- **Model + visibility.** All workflows pin `--model` (the action's default
  resolves to an invalid id). The implement workflow runs with
  `show_full_output: true` + `--verbose` so its turn-by-turn log is inspectable;
  drop those once runs are trusted. `timeout-minutes` caps every job.
