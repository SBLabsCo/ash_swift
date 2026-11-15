#!/usr/bin/env bash
#
# Tests for bin/pr-wait (ported from SBLabsCo/SwingClips#541), in three layers:
#   1. the workflow-trigger parser, against a fixture workflows/ dir covering every YAML
#      shape it must understand or fail safe on, plus one check against the real repo;
#   2. the pure decision (pr_wait_evaluate, pr_wait_settled, pr_wait_footer) as a table of
#      snapshots in, verdicts out — every state and reason lives here;
#   3. the script end-to-end against a stub `gh` (it serves fixture JSON and applies
#      the caller's own --jq, so the real bot-author filter runs) and a stub pr-threads —
#      wiring only: what is fetched, how often, and the exit codes.
#
#     bin/pr-wait.test.sh

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
cd "$HERE/.."

# shellcheck source=./test-lib.sh
. "$HERE/test-lib.sh"
# shellcheck source=./cli-lib.sh
. "$HERE/cli-lib.sh"
# shellcheck source=./pr-wait-lib.sh
. "$HERE/pr-wait-lib.sh"

H="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
OLD="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

test_workdir
WORKDIR="$TEST_WORKDIR"

# ---------------------------------------------------------------- 1. the trigger parser

echo "pr_wait_workflow_triggers (fixture workflows)"
WF="$WORKDIR/workflows"
mkdir -p "$WF"
w() { cat > "$WF/$1"; }
w block.yml <<'Y'
name: Block
on:
  push:
    branches: [main]
  pull_request:
    paths:
      - "a/**"
      - 'b/x.txt'   # quoted, commented
jobs:
  j: {}
Y
w flow.yml <<'Y'
name: Flow
on:
  pull_request:
    paths: [ "f/**", g/** ]
Y
w sameindent.yml <<'Y'
name: SameIndent
on:
  pull_request:
    paths:
    - "s/**"
    branches: [main]
Y
w inline.yml <<'Y'
name: Inline
on: pull_request
Y
w inlinelist.yml <<'Y'
name: InlineList
on: [push, pull_request]
Y
w fourspace.yml <<'Y'
name: FourSpace
on:
    pull_request:
        paths:
            - "four/**"
Y
w col0.yml <<'Y'
name: Col0
on:
  pull_request:
jobs:
  j: {}
Y
w noname.yml <<'Y'
on:
  pull_request:
    paths:
      - "n/**"
Y
w ignore.yml <<'Y'
name: Ignore
on:
  pull_request:
    paths-ignore:
      - "docs/**"
Y
w negation.yml <<'Y'
name: Negation
on:
  pull_request:
    paths:
      - "n/**"
      - "!n/skip/**"
Y
w negonly.yml <<'Y'
name: NegOnly
on:
  pull_request:
    paths:
      - "!n/skip/**"
Y
w emptypaths.yml <<'Y'
name: EmptyPaths
on:
  pull_request:
    paths:
    branches: [main]
Y
w target.yml <<'Y'
name: Target
on:
  pull_request_target:
    paths: ["t/**"]
Y
w pushonly.yml <<'Y'
name: PushOnly
# runs on pull_request? no: push only.
on:
  push:
    branches: [main]
jobs:
  j:
    if: github.event_name == 'pull_request'
Y
TRIG="$(pr_wait_workflow_triggers "$WF")"
has() { test_has_line yes "$1" "$2" "$TRIG"; }
hasnt() { test_has_line no "$1" "$2" "$TRIG"; }
has "block list: first glob" $'Block\ta/**'
has "block list: quoted, commented item" $'Block\tb/x.txt'
has "flow list" $'Flow\tf/**'
has "flow list: unquoted, second item" $'Flow\tg/**'
has "items at the key's own indent" $'SameIndent\ts/**'
eq "1" "  ...and the key after the list is not read as an item" "$(grep -c '^SameIndent' <<<"$TRIG")"
has "on: pull_request (inline) is unfiltered" $'Inline\t*'
has "on: [push, pull_request] is unfiltered" $'InlineList\t*'
has "4-space indent" $'FourSpace\tfour/**'
has "a column-0 key right after pull_request: ends the block" $'Col0\t*'
has "no name: falls back to the file path" "$WF/noname.yml"$'\tn/**'
has "paths-ignore is unfiltered (fails safe)" $'Ignore\t*'
has "a negation is skipped, the positive glob stays" $'Negation\tn/**'
hasnt "...and the negation is never a glob" $'Negation\t!n/skip/**'
has "only negations: unfiltered" $'NegOnly\t*'
has "paths: with no items: unfiltered" $'EmptyPaths\t*'
eq "0" "pull_request_target is not pull_request" "$(grep -c '^Target' <<<"$TRIG" || true)"
eq "0" "a comment or a job-level if mentioning pull_request does not count" "$(grep -c '^PushOnly' <<<"$TRIG" || true)"

echo
echo "pr_wait_workflow_triggers (the real repo)"
REAL="$(pr_wait_workflow_triggers "$HERE/../.github/workflows")"
missing=""
for f in "$HERE"/../.github/workflows/*.yml; do
  # Only the trigger block counts (a job-level `if:` naming pull_request is not a trigger).
  awk '/^jobs:/ { exit } !/^[[:space:]]*#/' "$f" | grep -qE 'pull_request([^_A-Za-z]|$)' || continue
  nm="$(sed -n 's/^name:[[:space:]]*//p' "$f" | head -1)"
  grep -qF "$nm"$'\t' <<<"$REAL" || missing+="$nm "
done
eq "" "every workflow that mentions pull_request is in the output" "$missing"

echo
echo "pr_wait_expected_workflows"
T=$'Elixir\tlib/**\nElixir\tbin/**\nElixir\tpriv/styles.css\nAlways\t*'
same $'Always\nElixir' "a nested path matches a /** glob" pr_wait_expected_workflows "$T" 'lib/ash_swift/x.ex'
same "Always" "unrelated files expect only the unfiltered workflow" pr_wait_expected_workflows "$T" $'docs/a.md\nSources/Foo.swift'
same $'Always\nElixir' "an exact-file glob matches" pr_wait_expected_workflows "$T" 'priv/styles.css'
same "Always" "...but not a sibling file" pr_wait_expected_workflows "$T" 'priv/other.css'
T2=$'Star\tlib/*.ex\nQ\tq/?.txt\nDot\ta.b/**'
same "Star" "a single * matches within a directory" pr_wait_expected_workflows "$T2" 'lib/x.ex'
same "" "...and does not cross a / (GitHub semantics)" pr_wait_expected_workflows "$T2" 'lib/ash_swift/x.ex'
same "Q" "? matches one non-/ character" pr_wait_expected_workflows "$T2" 'q/a.txt'
same "" "...not two" pr_wait_expected_workflows "$T2" 'q/ab.txt'
same "Dot" "a . in a glob is literal" pr_wait_expected_workflows "$T2" 'a.b/c/d'
same "" "...so it does not match any character" pr_wait_expected_workflows "$T2" 'aXb/c'

# ----------------------------------------------------------------- 2. the pure decision

echo
echo "pr_wait_footer"
F() { printf '<!-- ash-swift-review-verdict: {"v":1,"sha":"%s","must_fix":%s,"should_fix":0,"nit":0,"clean":%s} -->' "$1" "$2" "$3"; }
BODIES="$(F "$OLD" 0 true)"$'\n'"$(F "$H" 2 false)"$'\n'"some prose"$'\n'"$(F "$H" 0 true)"
same '{"v":1,"sha":"'"$H"'","must_fix":0,"should_fix":0,"nit":0,"clean":true}' \
  "the latest footer for the head wins" pr_wait_footer "$BODIES" "$H"
same "" "no footer for the head gives nothing" pr_wait_footer "$(F "$OLD" 0 true)" "$H"
status_is 0 "  ...and that is a clean empty, not grep's exit 1" pr_wait_footer "no footer here" "$H"
same "" "no comments at all" pr_wait_footer "" "$H"
same "" "a malformed footer is ignored" pr_wait_footer '<!-- ash-swift-review-verdict: {"v":1,"sha":"'"$H"'", -->' "$H"
same "" "an unknown format version is ignored" \
  pr_wait_footer '<!-- ash-swift-review-verdict: {"v":2,"sha":"'"$H"'","clean":true} -->' "$H"

echo
echo "pr_wait_settled"
NOWZ="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
cr() { # cr <status> <completedAt|null> [startedAt]
  jq -cn --arg s "$1" --argjson c "${2:-null}" --argjson t "${3:-null}" \
    '{__typename:"CheckRun", name:"x", workflowName:"W", status:$s, conclusion:null, startedAt:$t, completedAt:$c}'
}
expect yes "empty rollup, looked long enough" pr_wait_settled '[]' 90 100
expect no "empty rollup, not long enough" pr_wait_settled '[]' 90 10
expect no "an open check is never settled, however long the command has run" \
  pr_wait_settled "[$(cr IN_PROGRESS null '"2020-01-01T00:00:00Z"')]" 90 5000
expect yes "everything finished long ago" pr_wait_settled "[$(cr COMPLETED '"2020-01-01T00:00:00Z"')]" 90 0
expect no "everything finished just now: the window starts at completion, not at command start" \
  pr_wait_settled "[$(cr COMPLETED "\"$NOWZ\"")]" 1000 5000
expect no "a zero-time completion is not 'long ago'" \
  pr_wait_settled "[$(cr COMPLETED '"0001-01-01T00:00:00Z"')]" 90 5000

echo
echo "pr_wait_evaluate (snapshot in, verdict out)"
raw() { # raw <workflow> <name> <status> <conclusion|""> <startedAt|null>
  jq -cn --arg w "$1" --arg n "$2" --arg s "$3" --arg c "$4" --argjson t "$5" \
    '{__typename:"CheckRun", name:$n, workflowName:$w, status:$s, conclusion:(if $c=="" then null else $c end),
      startedAt:$t, completedAt:(if $s=="COMPLETED" then $t else null end)}'
}
T0='"2026-01-01T00:00:00Z"'; T1='"2026-01-01T01:00:00Z"'
G_BACKEND="$(raw "Elixir CI" "Compile" COMPLETED SUCCESS "$T0")"
G_REVIEW="$(raw "Claude PR review" review COMPLETED SUCCESS "$T0")"
G_DECL="$(raw "Lint" decl COMPLETED SUCCESS "$T0")"
BASE="$(jq -cn --arg h "$H" --argjson r "[$G_BACKEND,$G_REVIEW,$G_DECL]" --argjson f "$(F "$H" 0 true | sed -e 's/^<!-- ash-swift-review-verdict: //' -e 's/ -->$//')" '
  {pr:7, pr_state:"OPEN", head:$h, merge_state:"CLEAN", rollup:$r,
   expected:["Elixir CI","Claude PR review","Lint"], footer:$f, threads:0, settled:true}')"
verdict() { # verdict <desc> <jq patch on the snapshot> <jq assertion on the result>
  local out
  out="$(jq -c "$2" <<<"$BASE" | pr_wait_evaluate)"
  if jq -e "$3" <<<"$out" >/dev/null 2>&1; then test_pass "$1"; else test_fail "$1" "$out"; fi
}
verdict "all green, clean footer, no threads: merge_ready" '.' '.state == "done" and .merge_ready and .reasons == []'
verdict "BEHIND: not ready" '.merge_state = "BEHIND"' '(.merge_ready | not) and (.reasons | any(contains("behind")))'
verdict "DRAFT: not ready" '.merge_state = "DRAFT"' '(.merge_ready | not) and (.reasons | any(contains("draft")))'
verdict "BLOCKED: not ready, conservatively" '.merge_state = "BLOCKED"' '(.merge_ready | not) and (.reasons | any(contains("branch protection")))'
verdict "UNKNOWN: pending, waiting on the merge state" '.merge_state = "UNKNOWN"' '.state == "pending" and (.waiting_on | index("merge state"))'
verdict "DIRTY: needs_rebase" '.merge_state = "DIRTY"' '.state == "needs_rebase" and (.merge_ready | not)'
verdict "MERGED: never merge_ready, review still reported" '.pr_state = "MERGED"' '.state == "merged" and .review == "clean" and (.merge_ready | not)'
verdict "CLOSED: never merge_ready" '.pr_state = "CLOSED"' '.state == "closed" and (.merge_ready | not)'
verdict "findings: counts in the reason" '.footer = {v:1,sha:.head,must_fix:2,should_fix:1,nit:3,clean:false}' \
  '.review == "findings" and (.reasons | any(contains("must_fix 2") and contains("should_fix 1") and contains("nit 3")))'
verdict "no footer, review check finished: not_run" '.footer = null' '.review == "not_run" and (.merge_ready | not)'
verdict "no footer, review SKIPPED: not_run" '.footer = null | .rollup[1].conclusion = "SKIPPED"' '.review == "not_run" and (.merge_ready | not)'
verdict "no footer, review check running: pending" '.footer = null | .rollup[1] |= (.status = "IN_PROGRESS" | .conclusion = null)' \
  '.state == "pending" and .review == "pending"'
verdict "no review check yet, not settled: pending" '.footer = null | .settled = false | .rollup = [.rollup[0], .rollup[2]]' \
  '.state == "pending" and .review == "pending"'
verdict "no review check, settled: not_run" '.footer = null | .rollup = [.rollup[0], .rollup[2]]' '.review == "not_run"'
verdict "NEUTRAL and SKIPPED non-review checks are fine" '.rollup[0].conclusion = "NEUTRAL" | .rollup[2].conclusion = "SKIPPED"' '.merge_ready'
verdict "a FAILED check names itself" '.rollup[2].conclusion = "FAILURE"' '(.merge_ready | not) and (.reasons | any(. == "check failed: Lint / decl"))'
verdict "CANCELLED is a failure" '.rollup[2].conclusion = "CANCELLED"' '(.merge_ready | not)'
verdict "a StatusContext SUCCESS is fine" '.rollup += [{__typename:"StatusContext", context:"ci/x", state:"SUCCESS", startedAt:"2026-01-01T00:00:00Z"}]' '.merge_ready'
verdict "a StatusContext FAILURE fails, named without a workflow" '.rollup += [{__typename:"StatusContext", context:"ci/x", state:"FAILURE", startedAt:"2026-01-01T00:00:00Z"}]' \
  '(.merge_ready | not) and (.reasons | any(. == "check failed: ci/x"))'
verdict "a StatusContext PENDING is pending" '.rollup += [{__typename:"StatusContext", context:"ci/x", state:"PENDING", startedAt:"2026-01-01T00:00:00Z"}]' '.state == "pending"'
verdict "a newer green re-run supersedes an older failure" \
  ".rollup += [$(raw "Lint" decl COMPLETED FAILURE '"2025-01-01T00:00:00Z"')]" '.merge_ready'
verdict "an older green does not hide a newer failure" \
  ".rollup += [$(raw "Lint" decl COMPLETED FAILURE "$T1")]" '(.merge_ready | not)'
verdict "a queued re-run with a null startedAt beats the finished run: pending" \
  ".rollup += [$(raw "Lint" decl QUEUED '' null)]" '.state == "pending" and (.merge_ready | not) and (.waiting_on | index("check: decl"))'
verdict "a queued re-run with a zero startedAt beats the finished run: pending" \
  ".rollup += [$(raw "Lint" decl QUEUED '' '"0001-01-01T00:00:00Z"')]" '.state == "pending" and (.merge_ready | not)'
verdict "an expected workflow not yet registered, window open: pending" '.settled = false | .rollup = [.rollup[1], .rollup[2]]' \
  '.state == "pending" and .missing_workflows == ["Elixir CI"] and (.waiting_on | index("expected check: Elixir CI"))'
verdict "...window passed: done, not ready, and no longer waiting on it" '.rollup = [.rollup[1], .rollup[2]]' \
  '.state == "done" and (.merge_ready | not) and .waiting_on == [] and (.reasons | any(. == "expected check never appeared: Elixir CI"))'
verdict "unresolved threads block, with the count" '.threads = 2' '(.merge_ready | not) and (.reasons | any(startswith("2 unresolved")))'
verdict "a null thread count is itself a reason" '.threads = null' '(.merge_ready | not) and (.reasons | any(contains("unavailable")))'

# ------------------------------------------------------------------- 3. wiring (e2e)

echo
echo "bin/pr-wait end-to-end (stub gh + pr-threads)"
STUBS="$WORKDIR/stubs"
FIX="$WORKDIR/fix"
mkdir -p "$FIX"

# gh: pr view serves view.<n>.json (n = how many `pr view` calls so far, else view.json);
# api .../files and .../comments apply the caller's --jq to files.json / comments.json.
test_stub "$STUBS" gh <<'STUB'
fix="$TEST_FIX"
case "$1 $2" in
  "repo view") echo '{"owner":{"login":"o"},"name":"r"}' ;;
  "pr view")
    n="$(grep -c '^gh pr view' "$TEST_CALLS")"
    f="$fix/view.$n.json"; [[ -f "$f" ]] || f="$fix/view.json"
    cat "$f" ;;
  "api repos/o/r/pulls/7/files") jq -r '.[].filename' "$fix/files.json" ;;
  "api repos/o/r/issues/7/comments")
    q=""; while [[ $# -gt 0 ]]; do [[ "$1" == --jq ]] && q="$2"; shift; done
    jq -r "$q" "$fix/comments.json" ;;
  *) echo "stub gh: unexpected $*" >&2; exit 9 ;;
esac
STUB
export TEST_FIX="$FIX"

# The e2e runs read a fixture workflows dir, not this checkout's real one: Elixir CI is
# path-filtered to lib/**, the review and Lint run on every PR.
E2E_WF="$WORKDIR/e2e-workflows"
mkdir -p "$E2E_WF"
printf 'name: Elixir CI\non:\n  pull_request:\n    paths:\n      - "lib/**"\n' > "$E2E_WF/elixir.yml"
printf 'name: Claude PR review\non:\n  pull_request:\n' > "$E2E_WF/review.yml"
printf 'name: Lint\non:\n  pull_request:\n' > "$E2E_WF/lint.yml"

# pr-threads stub: prints $FIX/threads.json (default []), exits $FIX/threads.rc if present.
test_stub "$STUBS" pr-threads <<'STUB'
[[ ! -f "$TEST_FIX/threads.rc" ]] || exit "$(cat "$TEST_FIX/threads.rc")"
if [[ -f "$TEST_FIX/threads.json" ]]; then cat "$TEST_FIX/threads.json"; else echo '[]'; fi
STUB

GREEN=("$G_BACKEND" "$G_REVIEW" "$G_DECL")
# view <pr_state> <merge_state> <check>... — writes $FIX/view.json
view() {
  local st="$1" ms="$2"; shift 2
  printf '%s\n' "$@" | jq -sc --arg st "$st" --arg ms "$ms" --arg h "$H" \
    '{state:$st, headRefOid:$h, mergeStateStatus:$ms, statusCheckRollup:.}' > "$FIX/view.json"
}
comments() { # comments <user> <body>...  — one comment per body, all by <user>
  local u="$1"; shift
  printf '%s\n' "$@" | jq -Rsc --arg u "$u" 'split("\n")[:-1] | map({user:{login:$u}, body:.})' > "$FIX/comments.json"
}
reset() { rm -f "$FIX"/view.*json "$FIX/threads.json" "$FIX/threads.rc"; test_calls_reset
  echo '[{"filename":"lib/a.ex"}]' > "$FIX/files.json"
  comments github-actions[bot] "$(F "$H" 0 true)"
  view OPEN CLEAN "${GREEN[@]}"; }

run() { PATH="$STUBS:$PATH" PR_WAIT_THREADS_BIN="$STUBS/pr-threads" PR_WAIT_WORKFLOWS_DIR="$E2E_WF" PR_WAIT_INTERVAL=0.1 \
  PR_WAIT_UNKNOWN_SLEEP=0 PR_WAIT_SETTLE="${SETTLE:-0}" "$@"; }

reset
run test_run "all green, clean footer for the head, no threads: done and merge_ready" 0 \
  '.state == "done" and .merge_ready == true and .review == "clean" and .unresolved_threads == 0 and .head == "'"$H"'"' "" \
  bin/pr-wait 7 --timeout 0
eq "1" "  ...one PR read, no repeats" "$(test_calls_count '^gh pr view')"
test_called yes "  ...the repository comes from this checkout" "gh repo view"

reset
comments github-actions[bot] "$(F "$OLD" 0 true)"
run test_run "a footer for an OLDER commit is not this head's verdict" 0 \
  '.review == "not_run" and .merge_ready == false' "" bin/pr-wait 7 --timeout 0

reset
comments some-human "$(F "$H" 0 true)"
run test_run "a clean footer pasted by a human does not count" 0 \
  '.review == "not_run" and .merge_ready == false' "" bin/pr-wait 7 --timeout 0

reset
view OPEN DIRTY "$G_REVIEW"
run test_run "DIRTY: needs_rebase at once (exit 1), without waiting for checks" 1 \
  '.state == "needs_rebase"' "" bin/pr-wait 7 --timeout 600
eq "1" "  ...after a single look" "$(test_calls_count '^gh pr view')"

reset
echo '[{"id":"t1"},{"id":"t2"}]' > "$FIX/threads.json"
run test_run "the thread count comes from bin/pr-threads" 0 \
  '.unresolved_threads == 2 and .merge_ready == false' "" bin/pr-wait 7 --timeout 0

reset
echo 3 > "$FIX/threads.rc"
run test_run "a pr-threads failure is a tool failure (exit 3), not zero threads" 3 \
  '.ok == false' "pr-threads" bin/pr-wait 7 --timeout 0

reset
view OPEN UNKNOWN "${GREEN[@]}"
cp "$FIX/view.json" "$FIX/view.1.json"
view OPEN DIRTY "${GREEN[@]}"
cp "$FIX/view.json" "$FIX/view.2.json"
run test_run "UNKNOWN is re-read: the second look finds the conflict, even with --timeout 0" 1 \
  '.state == "needs_rebase"' "" bin/pr-wait 7 --timeout 0
eq "2" "  ...two reads" "$(test_calls_count '^gh pr view')"

reset
view OPEN UNKNOWN "${GREEN[@]}"
run test_run "UNKNOWN that never resolves: re-read a few times, then pending" 4 \
  '.state == "pending" and (.waiting_on | index("merge state"))' "" bin/pr-wait 7 --timeout 0
eq "4" "  ...the first look plus three re-reads" "$(test_calls_count '^gh pr view')"

echo
echo "late-starting workflows"
reset
NOWQ="\"$NOWZ\""
FRESH_REVIEW="$(raw "Claude PR review" review COMPLETED SUCCESS "$NOWQ")"
FRESH_DECL="$(raw "Lint" decl COMPLETED SUCCESS "$NOWQ")"
view OPEN CLEAN "$FRESH_REVIEW" "$FRESH_DECL"
cp "$FIX/view.json" "$FIX/view.1.json"
view OPEN CLEAN "$G_BACKEND" "$FRESH_REVIEW" "$FRESH_DECL"
cp "$FIX/view.json" "$FIX/view.2.json"
SETTLE=1000 run test_run "Elixir CI is expected (lib/ changed) but late: waits, then finds it" 0 \
  '.state == "done" and .merge_ready == true and .missing_workflows == []' "" \
  bin/pr-wait 7 --timeout 20
eq "2" "  ...it polled again" "$(test_calls_count '^gh pr view')"

reset
echo '[{"filename":"docs/x.md"}]' > "$FIX/files.json"
view OPEN CLEAN "$G_REVIEW" "$G_DECL"
run test_run "a docs-only diff does not expect Elixir CI: done" 0 \
  '.state == "done" and .merge_ready == true and (.expected_workflows | index("Elixir CI") | not)' "" \
  bin/pr-wait 7 --timeout 0

echo
echo "--timeout"
reset
view OPEN CLEAN "$G_BACKEND" "$(raw "Claude PR review" review IN_PROGRESS '' null)" "$G_DECL"
# 4s, not 1: each poll forks a stub gh + jq, and on a loaded CI runner one poll alone can
# outlast a 1s window — the "polled more than once" check below then races.
run test_run "a timeout while pending returns exit 4 with the JSON" 4 '.state == "pending"' "still pending" \
  bin/pr-wait 7 --timeout 4
eq "1" "  ...having polled more than once" "$([[ "$(test_calls_count '^gh pr view')" -gt 1 ]] && echo 1 || echo 0)"

echo
echo "usage"
test_run "no arguments" 2 "" "usage:" bin/pr-wait
test_run "a non-numeric PR" 2 "" "not a pull request number" bin/pr-wait abc
test_run "a bad --timeout" 2 "" "--timeout needs" bin/pr-wait 7 --timeout soon
test_run "--repo is gone" 2 "" "unknown argument" bin/pr-wait 7 --repo o/r
test_run "--help prints the header" 0 "*" "" bin/pr-wait --help

test_summary "pr-wait.test.sh"
