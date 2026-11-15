#!/usr/bin/env bash
#
# Tests for bin/after-merge and bin/after-merge-lib.sh (ported from SBLabsCo/SwingClips#540):
# the lib's pure functions against fixtures, then bin/after-merge end to end against a
# stub `gh` and a REAL throwaway repository with real linked worktrees (the worktree lookup
# by branch and the git teardown are the point). No network, never the real gh.
#
#     bin/after-merge.test.sh

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

# shellcheck source=./test-lib.sh
. "$HERE/test-lib.sh"
# shellcheck source=./after-merge-lib.sh
. "$HERE/after-merge-lib.sh"

echo "follow-ups document validation"
problem() { jq -r "$AFTER_MERGE_FOLLOWUPS_PROBLEM_JQ" <<<"$1"; }
same "" "a valid document has no problem" problem '[{"title":"T","body":"b","extra":1}]'
same "" "an empty array is valid" problem '[]'
same "must be a JSON array of {title, body}" "an object is not an array" problem '{"title":"T"}'
same "item 1 needs a non-empty string title" "a blank title is named by index" \
  problem '[{"title":"ok","body":"b"},{"title":"  ","body":"b"}]'
same "item 0 needs a non-empty string title" "a missing title" problem '[{"body":"b"}]'
same "item 0 title must be one line" "a multi-line title" problem '[{"title":"a\nb","body":"b"}]'
same "item 0 needs a string body" "a missing body" problem '[{"title":"T"}]'
same "item 0 is not an object" "a non-object item" problem '["T"]'

echo
echo "duplicate matching"
marker="$(after_merge_marker 551)"
same "Raised by the pre-PR refactor review of #551" "the marker line" echo "$marker"
ISSUES="[
 {\"number\":10,\"title\":\"Same words\",\"body\":\"x\n$marker.\"},
 {\"number\":11,\"title\":\"Same words\",\"body\":\"x\nRaised by the pre-PR refactor review of #552.\"},
 {\"number\":12,\"title\":\"Other\",\"body\":null}
]"
same "10" "exact title + this PR's marker matches" after_merge_followup_number "$ISSUES" "Same words" "$marker"
expect no "the same title raised by another PR is not a duplicate" \
  after_merge_followup_number "$ISSUES" "Same words" "$(after_merge_marker 553)"
expect no "a title that is only a substring is not a duplicate" after_merge_followup_number "$ISSUES" "Same" "$marker"
expect no "a null body never matches" after_merge_followup_number "$ISSUES" "Other" "$marker"
expect no "#5510 is not a match for #551" after_merge_followup_number \
  "[{\"number\":1,\"title\":\"T\",\"body\":\"Raised by the pre-PR refactor review of #5510.\"}]" "T" "$marker"
expect yes "a marker at the very end of the body matches" after_merge_followup_number \
  "[{\"number\":1,\"title\":\"T\",\"body\":\"$marker\"}]" "T" "$marker"


echo
echo "bin/after-merge end to end"
test_workdir
ROOT="$(cd "$TEST_WORKDIR" && pwd -P)"
STUBDIR="$ROOT/stubs"

# A throwaway repository holding a copy of the scripts under test, so the script resolves
# ITS main checkout (REPO_ROOT) here and never the real one.
MAIN="$ROOT/main"
git init -q -b main "$MAIN"
mkdir -p "$MAIN/bin"
cp "$HERE/after-merge" "$HERE/after-merge-lib.sh" "$HERE/cli-lib.sh" "$HERE/worktree-lib.sh" "$MAIN/bin/"
GIT="git -C $MAIN -c user.email=t@example.com -c user.name=t"
$GIT add -A
$GIT commit -q -m init
INIT_OID="$($GIT rev-parse HEAD)"
$GIT worktree add -q -b ticket-9-thing "$MAIN/.claude/worktrees/agent-abc"
$GIT worktree add -q -b ticket-8-dirty "$MAIN/.claude/worktrees/ticket-8"
$GIT worktree add -q -b ticket-6-ahead "$MAIN/.claude/worktrees/ticket-6"
$GIT worktree add -q -b ticket-5-locked "$MAIN/.claude/worktrees/ticket-5"
echo scribble > "$MAIN/.claude/worktrees/ticket-8/wip.txt"
git -C "$MAIN/.claude/worktrees/ticket-6" -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m "unpushed"
AM="$MAIN/bin/after-merge"
# untouched — no worktree or branch was removed by the last run().
untouched() { [[ "$(wt_list)" == "$WT_BEFORE" ]]; }

# Fake `gh`, driven by env: FAKE_PR_JSON, FAKE_ISSUE_STATE, FAKE_SEARCH (the
# `issue list --search` output), FAKE_LIST (the plain `issue list` output), FAKE_LIST_FAIL,
# FAKE_CREATE_FAIL (a title substring whose `issue create` fails), FAKE_PR_FAIL.
test_stub "$STUBDIR" gh <<'GH_STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "repo view") printf '{"owner":{"login":"SBLabsCo"},"name":"ash_swift"}' ;;
  "pr view")
    [[ -z "${FAKE_PR_FAIL:-}" ]] || { echo "gh: boom" >&2; exit 1; }
    printf '%s' "$FAKE_PR_JSON" ;;
  "issue view") printf '{"state":"%s"}' "${FAKE_ISSUE_STATE:-CLOSED}" ;;
  "issue list")
    if [[ "$*" == *--search* ]]; then printf '%s' "${FAKE_SEARCH:-[]}"
    else
      [[ -z "${FAKE_LIST_FAIL:-}" ]] || { echo "gh: list failed" >&2; exit 1; }
      printf '%s' "${FAKE_LIST:-[]}"
    fi ;;
  "issue create")
    if [[ -n "${FAKE_CREATE_FAIL:-}" && "$*" == *"$FAKE_CREATE_FAIL"* ]]; then
      echo "gh: create failed" >&2; exit 1
    fi
    echo "https://github.com/SBLabsCo/ash_swift/issues/$((700 + $(grep -c 'issue create' "$TEST_CALLS")))" ;;
  *) echo "unstubbed gh invocation: $*" >&2; exit 99 ;;
esac
GH_STUB

merged_pr() { # <branch> <closing issue numbers...> — head oid is the fixture's first commit
  local branch="$1"; shift
  local refs="[]" n
  for n in "$@"; do refs="$(jq -c --argjson n "$n" '. + [{number: $n}]' <<<"$refs")"; done
  jq -cn --arg b "$branch" --arg o "$INIT_OID" --argjson r "$refs" \
    '{state:"MERGED", mergedAt:"2026-10-09T00:00:00Z", headRefName:$b, headRefOid:$o, closingIssuesReferences:$r}'
}

wt_list() { git -C "$MAIN" worktree list --porcelain; git -C "$MAIN" branch --list; }
run() { # <description> <exit> <jq check or ""|*> <stderr substring> <args...>
  local what="$1" ec="$2" out="$3" err="$4"; shift 4
  test_calls_reset
  WT_BEFORE="$(wt_list)"
  test_run "$what" "$ec" "$out" "$err" env PATH="$STUBDIR:$PATH" "$AM" "$@"
}

export FAKE_ISSUE_STATE=CLOSED FAKE_SEARCH='[]' FAKE_LIST='[]'

echo "-- usage"
run "no PR is a usage error" 2 "" "missing <pr>"
run "a non-numeric PR is a usage error" 2 "" "not a pull request number" abc
run "an unknown flag is a usage error" 2 "" "unknown argument" 9 --frob
run "an unreadable --followups file is a usage error" 2 "" "cannot read" 9 --followups "$ROOT/nope.json"
run "--help prints the header" 0 "*" "" --help
test_called no "  ...and never reached gh" "gh "

echo "-- refusals change nothing"
export FAKE_PR_JSON='{"state":"OPEN","headRefName":"ticket-9-thing","closingIssuesReferences":[]}'
run "an open PR is refused" 1 '.reason == "not_merged"' "not merged" 9
expect yes "  ...nothing was torn down" untouched
export FAKE_PR_JSON='{"state":"CLOSED","headRefName":"ticket-9-thing","closingIssuesReferences":[]}'
run "a PR closed without merging is refused" 1 '.reason == "not_merged"' "CLOSED" 9

export FAKE_PR_JSON="$(merged_pr ticket-9-thing 540)"
echo '{"not":"an array"}' > "$ROOT/bad.json"
run "a bad follow-ups document is refused before anything happens" 1 '.reason == "bad_followups"' "must be a JSON array" \
  9 --followups "$ROOT/bad.json"
expect yes "  ...nothing was torn down" untouched
echo '[{"title":"","body":"b"}]' > "$ROOT/bad2.json"
run "an invalid item names its index" 1 '.reason == "bad_followups"' "item 0" 9 --followups "$ROOT/bad2.json"

export FAKE_PR_JSON="$(merged_pr ticket-8-dirty)"
run "a worktree with uncommitted changes is refused" 1 '.reason == "dirty_worktree"' "uncommitted changes" 9
expect yes "  ...nothing was torn down" untouched
expect yes "  ...and the worktree is still there" test -f "$MAIN/.claude/worktrees/ticket-8/wip.txt"
no_commit_advice() { [[ "$T_ERR" != *"then re-run"* && "$T_ERR" != *"Commit,"* ]]; }
expect yes "  ...and the message does not tell anyone to commit and re-run" no_commit_advice

export FAKE_PR_JSON="$(merged_pr ticket-6-ahead)"
run "a worktree ahead of the merged head (unpushed commits) is refused" 1 '.reason == "unmerged_commits"' "never merged" 9
expect yes "  ...nothing was torn down" untouched
expect yes "  ...and the worktree is still there" test -d "$MAIN/.claude/worktrees/ticket-6"

sleep 30 &
LIVE_PID=$!
git -C "$MAIN" worktree lock --reason "claude agent ticket-5 (pid $LIVE_PID)" "$MAIN/.claude/worktrees/ticket-5"
export FAKE_PR_JSON="$(merged_pr ticket-5-locked)"
run "a worktree locked by a live session is refused" 1 '.reason == "locked_worktree"' "live session" 9
expect yes "  ...nothing was torn down" untouched
kill "$LIVE_PID" 2>/dev/null || true
wait "$LIVE_PID" 2>/dev/null || true
git -C "$MAIN" worktree unlock "$MAIN/.claude/worktrees/ticket-5"
git -C "$MAIN" worktree lock --reason "claude agent ticket-5 (pid 2999999)" "$MAIN/.claude/worktrees/ticket-5"
run "a dead pid's lock does not stop the teardown" 0 '.worktree.action == "torn_down"' "" 9
expect no "  ...the stale-locked worktree is gone" test -d "$MAIN/.claude/worktrees/ticket-5"

export FAKE_PR_JSON="$(merged_pr main)"
run "the main checkout is never torn down" 1 '.reason == "main_checkout"' "main checkout" 9
expect yes "  ...nothing was torn down" untouched

export FAKE_PR_JSON="$(merged_pr ticket-9-thing)"
test_calls_reset
WT_BEFORE="$(wt_list)"
test_run "running from inside the ticket's own worktree is refused up front" 1 '.reason == "self_checkout"' "running from" \
  env PATH="$STUBDIR:$PATH" "$MAIN/.claude/worktrees/agent-abc/bin/after-merge" 9
expect yes "  ...nothing was torn down" untouched

FAKE_PR_FAIL=1 run "a gh failure is a tool failure" 3 '.reason == "gh_failed"' "failed" 9

echo "-- a merged PR: the worktree is found by branch, whatever its directory is called"
export FAKE_PR_JSON="$(merged_pr ticket-9-thing 540)"
# The harness's placeholder branches: one merged (deletable), one with its own commit (kept).
$GIT branch worktree-agent-abc "$INIT_OID"
run "the ticket worktree is torn down (stdout stays one JSON object)" 0 \
  ".ok and .merged and .worktree.action == \"torn_down\" and .worktree.path == \"$MAIN/.claude/worktrees/agent-abc\" and .followups == [] and .issues == [{number:540,state:\"closed\"}]" "removed worktree" 9
expect no "  ...the worktree directory is gone" test -d "$MAIN/.claude/worktrees/agent-abc"
expect no "  ...git no longer lists it" grep -qF "worktree $MAIN/.claude/worktrees/agent-abc" <<<"$(git -C "$MAIN" worktree list --porcelain)"
expect no "  ...its branch is deleted" git -C "$MAIN" show-ref --verify --quiet refs/heads/ticket-9-thing
expect no "  ...and the merged placeholder branch too" git -C "$MAIN" show-ref --verify --quiet refs/heads/worktree-agent-abc
expect yes "  ...main is never deleted" git -C "$MAIN" show-ref --verify --quiet refs/heads/main
test_called no "  ...no issue was created" "issue create"

$GIT worktree add -q -b ticket-4-ph "$MAIN/.claude/worktrees/ticket-4"
$GIT branch worktree-ticket-4 "$($GIT commit-tree -p "$INIT_OID" -m "placeholder's own" "$INIT_OID^{tree}")"
export FAKE_PR_JSON="$(merged_pr ticket-4-ph)"
run "a placeholder branch with commits beyond main is left alone" 0 '.worktree.action == "torn_down"' "has commits beyond main" 9
expect yes "  ...it still exists" git -C "$MAIN" show-ref --verify --quiet refs/heads/worktree-ticket-4
export FAKE_PR_JSON="$(merged_pr ticket-9-thing 540)"

echo "-- idempotence: the worktree is already gone"
run "a missing worktree is a no-op, not an error" 0 '.ok and .worktree.action == "none" and (.worktree | has("path") | not)' \
  "nothing to tear down" 9
expect yes "  ...nothing was torn down" untouched

echo "-- another repository"
run "--repo naming another repository skips the worktree step" 0 '.worktree.action == "skipped_other_repo"' "skipping the worktree step" \
  9 --repo Other/Repo
expect yes "  ...nothing was torn down" untouched
test_called yes "  ...and gh was pointed at that repository" "--repo Other/Repo"

echo "-- the closing issue is reported, not enforced"
FAKE_ISSUE_STATE=OPEN run "a still-open closing issue is reported and exit stays 0" 0 \
  '.ok and .issues == [{number:540,state:"open"}]' "issue #540 is still open" 9
export FAKE_PR_JSON="$(merged_pr ticket-9-thing)"
run "a PR that closes nothing says so" 0 '.issues == []' "closes no issue" 9
FAKE_PR_JSON="$(jq -c '.closingIssuesReferences = [{number:3,repository:{name:"ash_swift",owner:{login:"SBLabsCo"}}},{number:4,repository:{name:"other_repo",owner:{login:"SBLabsCo"}}}]' <<<"$FAKE_PR_JSON")" \
  run "a closing issue in another repository is skipped, not looked up here" 0 '.issues == [{number:3,state:"closed"}]' "skipping closing issue #4" 9
eq "1" "  ...only the local one was viewed" "$(test_calls_count 'issue view')"

echo "-- follow-ups"
cat > "$ROOT/fu.json" <<'JSON'
[{"title":"  Collapse the retry loops ","body":"Both loops in pr-wait."},
 {"title":"Rename `x`","body":"Because \"x\" says nothing."}]
JSON
run "each follow-up is filed as needs-triage (titles trimmed)" 0 \
  '.ok and (.followups | map(.action) == ["filed","filed"]) and (.followups[0].number == 701) and .followups[0].title == "Collapse the retry loops"' "filed follow-up" \
  9 --followups "$ROOT/fu.json"
eq "2" "  ...two issues were created" "$(test_calls_count 'issue create')"
test_called yes "  ...labelled needs-triage" "--label needs-triage"
test_called yes "  ...with the PR line in the body" "Raised by the pre-PR refactor review of #9."
test_called yes "  ...and the given body" "Both loops in pr-wait."
test_called yes "  ...and titles with quotes and backticks survive" '--title Rename `x`'

echo "-- follow-ups: a re-run files nothing twice"
export FAKE_SEARCH='[{"number":701,"title":"Collapse the retry loops","body":"Both loops in pr-wait.\n\nRaised by the pre-PR refactor review of #9."},
  {"number":702,"title":"Rename `x`","body":"Because.\n\nRaised by the pre-PR refactor review of #9."}]'
run "already-filed follow-ups are duplicates" 0 \
  '.ok and (.followups | map(.action) == ["duplicate","duplicate"]) and .followups[1].number == 702' "already filed" \
  9 --followups "$ROOT/fu.json"
eq "0" "  ...nothing was created" "$(test_calls_count 'issue create')"

echo "-- follow-ups: the search index lags a fresh filing"
export FAKE_SEARCH='[]'
export FAKE_LIST='[{"number":701,"title":"Collapse the retry loops","body":"x\n\nRaised by the pre-PR refactor review of #9."}]'
run "an issue only the plain listing shows is not filed twice" 0 \
  '(.followups | map(.action) == ["duplicate","filed"]) and .followups[0].number == 701' "" 9 --followups "$ROOT/fu.json"
eq "1" "  ...only the unseen one was created" "$(test_calls_count 'issue create')"
export FAKE_LIST='[]'

cat > "$ROOT/dupes.json" <<'JSON'
[{"title":"Twice","body":"a"},{"title":"Twice","body":"b"}]
JSON
run "a title repeated within the file is filed once, and reports the real number" 0 \
  '.followups | map(.action) == ["filed","duplicate"] and .[1].number == .[0].number and .[0].number == 701' "" \
  9 --followups "$ROOT/dupes.json"

echo "[]" > "$ROOT/none.json"
run "an empty follow-ups list files nothing and does not search" 0 '.followups == []' "" 9 --followups "$ROOT/none.json"
test_called no "  ...no issue list" "issue list"

echo "-- reads happen before any mutation"
FAKE_LIST_FAIL=1 run "a failing issue listing refuses with exit 3 before teardown or filing" 3 '.reason == "gh_failed"' "failed" \
  9 --followups "$ROOT/fu.json"
expect yes "  ...nothing was torn down" untouched
test_called no "  ...nothing was filed" "issue create"

echo "-- partial failures finish the rest and exit 3"
FAKE_CREATE_FAIL="Rename" run "one follow-up failing does not stop the next" 3 \
  '(.ok | not) and .reason == "followups_failed" and (.followups | map(.action) == ["filed","failed"])' "could not file" \
  9 --followups "$ROOT/fu.json"

# A worktree git cannot remove: its parent directory is read-only.
mkdir -p "$MAIN/.claude/stuck"
$GIT worktree add -q -b ticket-7-late "$MAIN/.claude/stuck/late"
chmod 555 "$MAIN/.claude/stuck"
export FAKE_PR_JSON="$(merged_pr ticket-7-late)"
run "a failing teardown is reported, follow-ups still filed, exit 3" 3 \
  '(.ok | not) and .reason == "teardown_failed" and .worktree.action == "failed" and (.followups | length == 2)' "finished with failures" \
  9 --followups "$ROOT/fu.json"
chmod 755 "$MAIN/.claude/stuck"
$GIT worktree add -q -b ticket-3-late "$MAIN/.claude/stuck/late3"
chmod 555 "$MAIN/.claude/stuck"
export FAKE_PR_JSON="$(merged_pr ticket-3-late)"
FAKE_CREATE_FAIL="Rename" run "when both fail, both reasons are carried" 3 \
  '.reason == "teardown_failed" and .reasons == ["teardown_failed","followups_failed"]' "teardown_failed, followups_failed" \
  9 --followups "$ROOT/fu.json"
chmod 755 "$MAIN/.claude/stuck"

echo "-- the main checkout is fast-forwarded when that is safe"
# A REAL origin and clone (the move is exactly what must not be faked); the clone carries
# its own copy of the scripts, so it is the main checkout the script resolves. Its
# .claude/worktrees is gitignored, as in the real repository.
SYNC_DIR="$ROOT/sync"
mkdir -p "$SYNC_DIR"
test_git_origin "$SYNC_DIR"
SM="$TEST_CLONE" SORIGIN="$TEST_ORIGIN"
mkdir -p "$SM/bin"
cp "$HERE/after-merge" "$HERE/after-merge-lib.sh" "$HERE/cli-lib.sh" "$HERE/worktree-lib.sh" "$SM/bin/"
echo ".claude/worktrees/" > "$SM/.gitignore"
git -C "$SM" add -A
git -C "$SM" commit -q -m "scripts"
git -C "$SM" push -q origin main 2>/dev/null
SAM="$SM/bin/after-merge"
export FAKE_PR_JSON="$(merged_pr ticket-1-gone)"
sm_run() { # <description> <exit> <jq check> <stderr substring> — after-merge in the sync checkout
  test_calls_reset
  test_run "$1" "$2" "$3" "$4" env PATH="$STUBDIR:$PATH" "$SAM" 9
}
sm_head() { git -C "$SM" rev-parse HEAD; }

sm_run "an up-to-date main checkout is reported already_current" 0 '.ok and .main_checkout == {action: "already_current"}' ""

TEST_ORIGIN="$SORIGIN" test_git_advance_origin
OLD="$(sm_head)"
NEW="$(git -C "$SORIGIN" rev-parse main)"
sm_run "a clean main checkout on main is fast-forwarded" 0 \
  ".ok and .main_checkout == {action: \"fast_forwarded\", from: \"$OLD\", to: \"$NEW\"}" "fast-forwarded"
eq "$NEW" "  ...HEAD is origin/main" "$(sm_head)"
eq "$(git -C "$SM" rev-parse "$NEW^")" "  ...by a fast-forward (no merge commit)" "$OLD"

TEST_ORIGIN="$SORIGIN" test_git_advance_origin
echo scribble > "$SM/notes.txt"
OLD="$(sm_head)"
sm_run "an untracked file in the main checkout stops it, and says so" 0 \
  '.ok and .main_checkout.action == "skipped" and (.main_checkout.reason | contains("local changes"))' "has local changes"
eq "$OLD" "  ...HEAD did not move" "$(sm_head)"
expect yes "  ...and the file is untouched" test -f "$SM/notes.txt"
rm "$SM/notes.txt"
echo edit >> "$SM/README"
sm_run "an uncommitted edit stops it" 0 '.main_checkout.action == "skipped"' "has local changes"
git -C "$SM" checkout -q -- README
mkdir -p "$SM/.claude/worktrees/some-wt"
echo ignored > "$SM/.claude/worktrees/some-wt/file"

git -C "$SM" checkout -q -b feature
sm_run "a main checkout on another branch is left alone" 0 \
  '.main_checkout.action == "skipped" and (.main_checkout.reason | contains("on branch feature"))' "on branch feature"
eq "$OLD" "  ...HEAD did not move" "$(sm_head)"
git -C "$SM" checkout -q main

git -C "$SM" -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m "local only"
LOCAL="$(sm_head)"
sm_run "local commits that make it a non-fast-forward are left alone" 0 \
  '.main_checkout.action == "skipped" and (.main_checkout.reason | contains("not a fast-forward"))' "not a fast-forward"
eq "$LOCAL" "  ...HEAD did not move" "$(sm_head)"
git -C "$SM" reset -q --hard "$OLD"

git -C "$SM" worktree add -q -b ticket-2-other "$SM/.claude/worktrees/ticket-2" origin/main~1
WT_HEAD="$(git -C "$SM/.claude/worktrees/ticket-2" rev-parse HEAD)"
sm_run "an ignored worktree directory does not count as local changes" 0 '.main_checkout.action == "fast_forwarded"' ""
eq "$WT_HEAD" "  ...and a linked worktree's checkout is never touched" "$(git -C "$SM/.claude/worktrees/ticket-2" rev-parse HEAD)"

test_summary "after-merge.test.sh"
