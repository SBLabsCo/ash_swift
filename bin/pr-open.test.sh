#!/usr/bin/env bash
#
# Tests for bin/pr-open: the pure body helpers in bin/pr-open-lib.sh directly, then
# bin/pr-open end-to-end against REAL git (a throwaway origin and clone — the push is
# exactly what must not be faked) with a stub `gh` on PATH. No network.
#
#     bin/pr-open.test.sh

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

# shellcheck source=./test-lib.sh
. "$HERE/test-lib.sh"
# shellcheck source=./pr-open-lib.sh
. "$HERE/pr-open-lib.sh"

echo "pr_open_compose_body"
BODY="$(pr_open_compose_body "Adds the thing." 539 "- F1: declined, because")"
test_has_line yes "closes the issue" "Closes #539" "$BODY"
test_has_line yes "declined section heading" "## Declined review findings" "$BODY"
eq "$PR_OPEN_ATTRIBUTION" "attribution is the last line" "$(printf '%s\n' "$BODY" | tail -n1)"
eq '🤖 Generated with [Claude Code](https://claude.com/claude-code)' "the attribution is the Claude Code line" "$PR_OPEN_ATTRIBUTION"
MIN="$(pr_open_compose_body "S" 7 "")"
expect no "no declined heading when nothing declined" grep -qF "Declined" <<<"$MIN"

echo
echo "reading a body back"
same "Adds the thing." "the summary is what precedes Closes" pr_open_existing_summary "$BODY" 539
same "" "a body without that Closes line has no summary" pr_open_existing_summary "$BODY" 540
SUM2=$'Line one.\n\nLine two.'
same "$SUM2" "a multi-paragraph summary survives a round trip" \
  pr_open_existing_summary "$(pr_open_compose_body "$SUM2" 5 "")" 5
same "- F1: declined, because" "the declined section is read back without its heading" pr_open_declined_section "$BODY"
same "" "no declined section, no output" pr_open_declined_section "$MIN"
same "" "a template-shaped body has nothing unrecognised" pr_open_unrecognized "$BODY" 539
same $'## Notes\nhand-written' "extra content after Closes is reported" \
  pr_open_unrecognized "$(pr_open_compose_body S 5 "")"$'\n\n## Notes\n\nhand-written' 5

echo
echo "bin/pr-open end-to-end (real git, stub gh)"

test_workdir
WORKDIR="$(cd "$TEST_WORKDIR" && pwd -P)"
STUBDIR="$WORKDIR/stubs"
OUTBODY="$WORKDIR/last-body.md"

test_git_origin "$WORKDIR"
ORIGIN="$TEST_ORIGIN" CLONE="$TEST_CLONE"
# The rationale file must not dirty the worktree; the throwaway clone ignores it locally.
echo ".pr-declined*.md" >> "$CLONE/.git/info/exclude"

# Fake gh. `pr list` serves FAKE_PRS_JSON; `pr create` / `pr edit` copy their --body-file to
# $OUTBODY so a test can read the body that would have been sent; `pr create` prints a URL
# (with a warning on stderr, which must never corrupt it).
test_stub "$STUBDIR" gh <<'GH_STUB'
#!/usr/bin/env bash
if [[ -n "${FAKE_GH_FAILS_ON:-}" && "$1 $2" == "$FAKE_GH_FAILS_ON"* ]]; then echo "gh: HTTP 502" >&2; exit 1; fi
body_file() { while [[ $# -gt 0 ]]; do [[ "$1" == --body-file ]] && { cat "$2"; return; }; shift; done; }
case "$1 $2" in
  "repo view") printf '%s' '{"owner":{"login":"SBLabsCo"},"name":"ash_swift"}' ;;
  "pr list") printf '%s' "${FAKE_PRS_JSON:-[]}" ;;
  "issue view") echo "bin/pr-open — the issue title" ;;
  "pr create") body_file "$@" > "$OUTBODY"; echo "Warning: 1 uncommitted change" >&2; echo "https://github.com/SBLabsCo/ash_swift/pull/${FAKE_NEW_PR:-901}" ;;
  "pr edit") body_file "$@" > "$OUTBODY" ;;
  *) echo "unstubbed gh invocation: $*" >&2; exit 99 ;;
esac
GH_STUB


# A ticket branch off main with one commit touching $2 (default: a docs file).
new_ticket() {
  local issue="$1" path="${2:-docs/note.md}" branch="ticket-$1-thing"
  git -C "$CLONE" checkout -q main
  git -C "$CLONE" checkout -q -b "$branch"
  mkdir -p "$CLONE/$(dirname "$path")"
  echo "change $RANDOM" > "$CLONE/$path"
  git -C "$CLONE" add "$path"
  git -C "$CLONE" commit -q -m "change"
}
po() { ( cd "$CLONE" && env PATH="$STUBDIR:$PATH" OUTBODY="$OUTBODY" FAKE_PRS_JSON="${FAKE_PRS_JSON:-[]}" "$HERE/pr-open" "$@" ); }
reset_world() { test_calls_reset;rm -f "$OUTBODY"; FAKE_PRS_JSON="[]"; rm -f "$CLONE"/.pr-declined*.md; }
body() { cat "$OUTBODY"; }

reset_world
new_ticket 539
HEAD_NOW="$(git -C "$CLONE" rev-parse HEAD)"
test_run "opens a PR: JSON carries number, url, head sha, created" 0 \
  ".ok == true and .pr == 901 and .url == \"https://github.com/SBLabsCo/ash_swift/pull/901\" and .head_sha == \"$HEAD_NOW\" and .action == \"created\" and .issue == 539" \
  "opened PR #901" po 539 --summary "Adds pr-open."
test_called yes "  ...against main, from the branch" "--base main --head ticket-539-thing"
test_called yes "  ...titled from the issue" "--title bin/pr-open — the issue title"
test_has_line yes "  ...body closes the issue" "Closes #539" "$(body)"
test_has_line yes "  ...body has the summary" "Adds pr-open." "$(body)"
eq "$PR_OPEN_ATTRIBUTION" "  ...body ends with the attribution" "$(body | tail -n1)"
eq "$HEAD_NOW" "  ...and the branch really is pushed" "$(git -C "$ORIGIN" rev-parse ticket-539-thing)"

reset_world
echo "Summary from a file." > "$WORKDIR/summary.md"
test_run "--summary-file is the summary" 0 '.action == "created"' "" po 539 --summary-file "$WORKDIR/summary.md"
test_has_line yes "  ...body has it" "Summary from a file." "$(body)"
reset_world
test_run "--title overrides the issue's title" 0 '.action == "created"' "" po 539 --summary S --title "Custom title"
test_called yes "  ...passed to gh" "--title Custom title"
test_called no "  ...and the issue is not consulted for one" "issue view"

reset_world
echo "- F1: not a bug, because X." > "$CLONE/.pr-declined-539.md"
test_run "rationales from the default per-issue file" 0 '.action == "created"' "" po 539 --summary "S"
test_has_line yes "  ...rationale verbatim" "- F1: not a bug, because X." "$(body)"
reset_world
echo "- stale" > "$CLONE/.pr-declined-999.md"
echo "- old name" > "$CLONE/.pr-declined.md"
test_run "another ticket's (or the old unnumbered) file is never read" 0 '.action == "created"' "" po 539 --summary "S"
test_has_line no "  ...stale rationale absent" "- stale" "$(body)"
test_has_line no "  ...old-name rationale absent" "- old name" "$(body)"
reset_world
echo "- Y" > "$WORKDIR/elsewhere.md"
test_run "--rationale-file overrides the path" 0 '.action == "created"' "" po 539 --summary "S" --rationale-file "$WORKDIR/elsewhere.md"
test_has_line yes "  ...its content is used" "- Y" "$(body)"
reset_world
printf '\n  \n' > "$CLONE/.pr-declined-539.md"
test_run "a blank rationale file adds no section" 0 '.action == "created"' "" po 539 --summary "S"
test_has_line no "  ...no heading" "## Declined review findings" "$(body)"

echo
echo "usage and refusals"
reset_world
test_run "no issue is a usage error" 2 "" "need an issue number" po
test_run "a non-number is a usage error" 2 "" "need an issue number" po abc --summary x
test_run "an unknown option is a usage error" 2 "" "unknown option" po 539 --bogus
test_run "no summary on a fresh PR is a usage error" 2 "" "need --summary" po 539
test_run "--summary and --summary-file together" 2 "" "exclusive" po 539 --summary a --summary-file /dev/null
test_run "an unreadable --summary-file is exit 3, and names the issue" 3 '.reason == "file_unreadable" and .issue == 539' "cannot read" po 539 --summary-file "$WORKDIR/nope"
test_run "--help prints usage and exits 0" 0 "*" "" po --help

reset_world
test_run "a branch of another ticket is refused" 1 '.reason == "wrong_branch"' "not a ticket-540" po 540 --summary S
git -C "$CLONE" checkout -q main
test_run "main itself is refused" 1 '.reason == "wrong_branch"' "" po 539 --summary S
git -C "$CLONE" checkout -q ticket-539-thing
new_ticket 5390
test_run "ticket-5390-thing is not issue 539's branch (digit-prefix trap)" 1 '.reason == "wrong_branch"' "" po 539 --summary S
git -C "$CLONE" checkout -q ticket-539-thing

echo dirty >> "$CLONE/docs/note.md"
test_run "uncommitted changes are refused" 1 '.reason == "dirty_worktree"' "uncommitted" po 539 --summary S
git -C "$CLONE" checkout -q -- docs/note.md

git -C "$CLONE" checkout -q main
git -C "$CLONE" checkout -q -b ticket-541-empty
test_run "a branch with nothing ahead of main is refused" 1 '.reason == "no_commits"' "no commits ahead" po 541 --summary S
git -C "$CLONE" checkout -q main

echo
echo "re-running updates, never opens a second PR"
reset_world
new_ticket 610 lib/b.ex
OLD="$(pr_open_compose_body "First summary." 610 "- old rationale")"
export FAKE_PRS_JSON="$(jq -cn --arg b "$OLD" '[{number:77,url:"https://github.com/SBLabsCo/ash_swift/pull/77",body:$b}]')"
echo "- F9: declined, because Z." > "$CLONE/.pr-declined-610.md"
test_run "an existing PR is edited" 0 '.action == "updated" and .pr == 77 and .url == "https://github.com/SBLabsCo/ash_swift/pull/77"' "updated PR #77" po 610
test_called no "  ...no second PR" "pr create"
test_called yes "  ...edited by number" "pr edit 77"
test_has_line yes "  ...summary reused" "First summary." "$(body)"
test_has_line yes "  ...the new rationale is in" "- F9: declined, because Z." "$(body)"
test_has_line no "  ...and the file replaced the old section" "- old rationale" "$(body)"
eq "$PR_OPEN_ATTRIBUTION" "  ...attribution still last" "$(body | tail -n1)"
test_run "a new summary overrides the old one" 0 '.action == "updated"' "" po 610 --summary "Second."
test_has_line yes "  ...new summary" "Second." "$(body)"
test_has_line no "  ...old summary gone" "First summary." "$(body)"
rm -f "$CLONE/.pr-declined-610.md"
test_run "an ABSENT rationale file keeps the existing section" 0 '.action == "updated"' "" po 610 --summary "Third."
test_has_line yes "  ...old rationale still there" "- old rationale" "$(body)"
printf '\n' > "$CLONE/.pr-declined-610.md"
test_run "an EMPTY rationale file removes it" 0 '.action == "updated"' "" po 610 --summary "Fourth."
test_has_line no "  ...old rationale gone" "- old rationale" "$(body)"
test_has_line no "  ...heading gone" "## Declined review findings" "$(body)"

echo
echo "dropped content is warned about"
reset_world
export FAKE_PRS_JSON="$(jq -cn --arg b "$(pr_open_compose_body "First summary." 610 "")"$'\n\n## Notes\n\nhand-written' '[{number:77,url:"u",body:$b}]')"
test_run "extra content in the old body is dropped with a warning" 0 '.action == "updated"' "drops content the template has no slot for, starting with: ## Notes" po 610
test_has_line no "  ...and really gone" "hand-written" "$(body)"

echo
echo "an unchanged body is not rewritten"
reset_world
export FAKE_PRS_JSON="$(jq -cn --arg b "$(pr_open_compose_body "First summary." 610 "")" '[{number:77,url:"u",body:$b}]')"
test_run "same inputs, same body: updated, but no edit call, no warning" 0 '.action == "updated"' "already current" po 610
test_called no "  ...gh pr edit not called" "pr edit"
expect no "  ...and no dropped-content warning" grep -qF "drops content" <<<"$T_ERR"

echo
echo "pushing"
reset_world
export FAKE_PRS_JSON="[]"
new_ticket 630
test_run "first push + create" 0 '.action == "created"' "" po 630 --summary S
git -C "$CLONE" commit -q --amend -m "amended"
test_run "after a rebase/amend the plain push is rejected: its own reason, exit 1" 1 '.reason == "push_rejected"' "--force-with-lease" po 630 --summary S
test_run "--force-with-lease lands it" 0 '.ok == true' "" po 630 --summary S --force-with-lease
eq "$(git -C "$CLONE" rev-parse HEAD)" "  ...the remote now has the amended commit" "$(git -C "$ORIGIN" rev-parse ticket-630-thing)"

echo
echo "tool failures"
reset_world
export FAKE_PRS_JSON="[]"
new_ticket 620
FAKE_GH_FAILS_ON="pr list" test_run "a gh failure is exit 3 and nothing is pushed" 3 '.reason == "gh_failed"' "failed" po 620 --summary S
eq "" "  ...the branch was not pushed" "$(git -C "$ORIGIN" branch --list ticket-620-thing)"
FAKE_GH_FAILS_ON="pr create" test_run "gh pr create failing after the push is exit 3" 3 '.reason == "gh_failed"' "failed" po 620 --summary S
eq "ticket-620-thing" "  ...the branch is pushed" "$(git -C "$ORIGIN" branch --list ticket-620-thing | tr -d ' ')"
test_run "  ...and a re-run creates the PR" 0 '.action == "created" and .pr == 901' "" po 620 --summary S
new_ticket 650
printf '#!/bin/sh\necho "no pushes today" >&2\nexit 1\n' > "$ORIGIN/hooks/pre-receive"
chmod +x "$ORIGIN/hooks/pre-receive"
test_run "a server-side hook refusal is a git failure, not push_rejected" 3 '.reason == "git_failed"' "" po 650 --summary S
rm -f "$ORIGIN/hooks/pre-receive"
git -C "$CLONE" checkout -q ticket-620-thing
git -C "$CLONE" remote set-url origin "$WORKDIR/nonexistent.git"
test_run "an unreachable remote is exit 3" 3 '.reason == "git_failed"' "git fetch" po 620 --summary S

test_summary "pr-open.test.sh"
