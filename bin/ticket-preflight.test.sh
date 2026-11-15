#!/usr/bin/env bash
#
# Tests for bin/ticket-preflight: the pure helpers in bin/ticket-preflight-lib.sh
# directly, then bin/ticket-preflight end-to-end in three groups:
#   - the default worktree-creating mode, against stub `git`, `gh` and `mix` binaries on
#     PATH (no network; the stub `git worktree add` only makes a directory under a
#     throwaway "main checkout"),
#   - `--check-only`, against the stub gh with no git at all,
#   - `--in-place`, against REAL git (a throwaway origin, clone and linked worktree) with
#     only gh and mix stubbed — a branch switch is exactly what must not be faked.
#
#     bin/ticket-preflight.test.sh

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

# shellcheck source=./test-lib.sh
. "$HERE/test-lib.sh"
# shellcheck source=./ticket-preflight-lib.sh
. "$HERE/ticket-preflight-lib.sh"
# shellcheck source=./ticket-lib.sh
. "$HERE/ticket-lib.sh"
echo
echo "ticket_preflight_has_label"
expect yes "finds the label" ticket_preflight_has_label '{"labels":[{"name":"x"},{"name":"ready-for-agent"}]}' ready-for-agent
expect no "missing label" ticket_preflight_has_label '{"labels":[{"name":"needs-triage"}]}' ready-for-agent
expect no "no labels at all" ticket_preflight_has_label '{"labels":[]}' ready-for-agent

echo
echo "ticket_preflight_open_prs"
PRS='[{"number":10,"body":"Closes #538","closingIssuesReferences":[]},
      {"number":11,"body":"fixes #5381","closingIssuesReferences":[]},
      {"number":12,"body":null,"closingIssuesReferences":[{"number":538}]},
      {"number":13,"body":"unrelated, mentions #538","closingIssuesReferences":[]}]'
same $'10\n12' "keyword in body or GitHub's own link; #5381 and a bare mention don't match" \
  ticket_preflight_open_prs "$PRS" 538
same "" "no PR closes it" ticket_preflight_open_prs "$PRS" 999
status_is 0 "  ...and jq ran cleanly" ticket_preflight_open_prs "$PRS" 999
same "" "an empty list" ticket_preflight_open_prs '[]' 538
status_is 0 "  ...and jq ran cleanly" ticket_preflight_open_prs '[]' 538

echo
echo "ticket_preflight_open_blockers"
same $'#3' "only open blockers are named" \
  ticket_preflight_open_blockers '[{"number":3,"state":"open"},{"number":4,"state":"closed"}]'

echo
echo "bin/ticket-preflight end-to-end (stub git/gh/mix)"

test_workdir
# Resolved: the script reports the main checkout's symlink-resolved path.
WORKDIR="$(cd "$TEST_WORKDIR" && pwd -P)"
STUBDIR="$WORKDIR/stubs"        # gh + mix
FAKEGIT="$WORKDIR/fakegit"      # the fake git, only on PATH for the worktree-mode runs
MAIN="$WORKDIR/main"
mkdir -p "$MAIN/.git" "$WORKDIR/elsewhere"

# Fake git: the "main checkout" is $MAIN. `worktree list` prints $FAKE_WORKTREE_LIST;
# `worktree add` only mkdirs <path>. Every call is logged to $TEST_CALLS by test_stub.
test_stub "$FAKEGIT" git <<'GIT_STUB'
#!/usr/bin/env bash
had_c=""
if [[ "$1" == "-C" ]]; then had_c="$2"; shift 2; fi
case "$1" in
  # Resolved from the script's own repo (-C) it is the fake main; resolved from the
  # caller's cwd (no -C) it is some unrelated repo — the bug this guards against.
  rev-parse)
    if [[ -n "$had_c" ]]; then printf '%s\n' "$FAKE_MAIN/.git"; else printf '%s\n' "$FAKE_OTHER_REPO/.git"; fi
    ;;
  checkout|switch) echo "git $1 must never run in worktree mode" >&2; exit 97 ;;
  worktree)
    case "$2" in
      list) printf '%s' "${FAKE_WORKTREE_LIST:-}" ;;
      add)
        [[ -z "${FAKE_WORKTREE_ADD_FAILS:-}" ]] || { echo "fatal: branch exists" >&2; exit 128; }
        # args: worktree add --no-track -b <branch> <path> <start>
        mkdir -p "$6"
        ;;
    esac
    ;;
  fetch)
    echo "remote: Enumerating objects: 4242, done."
    [[ -z "${FAKE_FETCH_FAILS:-}" ]] || { echo "fatal: could not read from remote repository" >&2; exit 128; }
    ;;
  *) echo "unstubbed git invocation: $*" >&2; exit 99 ;;
esac
GIT_STUB

# Fake gh: serves FAKE_ISSUE_JSON (issue view), FAKE_PRS_JSON (pr list), FAKE_BLOCKED_BY
# (the summary count) and FAKE_DEPS_JSON (the blocked_by list).
test_stub "$STUBDIR" gh <<'GH_STUB'
#!/usr/bin/env bash
if [[ -n "${FAKE_GH_FAILS:-}" ]]; then echo "gh: auth login required" >&2; exit 4; fi
# FAKE_GH_FAILS_ON: fail only the call whose "<cmd> <sub>" starts with this.
if [[ -n "${FAKE_GH_FAILS_ON:-}" && "$1 $2" == "$FAKE_GH_FAILS_ON"* ]]; then echo "gh: HTTP 502" >&2; exit 1; fi
# FAKE_GH_WARN: a warning on stderr alongside a perfectly good, successful response.
[[ -z "${FAKE_GH_WARN:-}" ]] || echo "$FAKE_GH_WARN" >&2
case "$1 $2" in
  "repo view") echo "gh-cwd: $PWD" >> "$TEST_CALLS"; printf '%s''{"owner":{"login":"SBLabsCo"},"name":"ash_swift"}' ;;
  "issue view") printf '%s' "$FAKE_ISSUE_JSON" ;;
  "pr list") printf '%s' "$FAKE_PRS_JSON" ;;
  "api repos/"*"/dependencies/blocked_by") printf '%s' "$FAKE_DEPS_JSON" ;;
  "api repos/"*) printf '%s' "$FAKE_BLOCKED_BY" ;;
  *) echo "unstubbed gh invocation: $*" >&2; exit 99 ;;
esac
GH_STUB

# Fake mix: chatters on success (a quiet script must not pass it through), and on failure
# says why (the script must show the tail).
test_stub "$STUBDIR" mix <<'MIX_STUB'
#!/usr/bin/env bash
echo "mix: in $(basename "$PWD")" >> "$TEST_CALLS"
echo "Resolving Hex dependencies..."
[[ -z "${FAKE_MIX_FAILS:-}" ]] || { echo "** (Mix) could not reach hex.pm" >&2; exit 1; }
MIX_STUB

export FAKE_MAIN="$MAIN" FAKE_OTHER_REPO="$WORKDIR/elsewhere"
WT="$MAIN/.claude/worktrees/ticket-538"

reset_world() {
  test_calls_reset
  rm -rf "$MAIN/.claude"
  FAKE_ISSUE_JSON='{"state":"OPEN","title":"bin/ticket-preflight — refuse an unready ticket","labels":[{"name":"ready-for-agent"}]}'
  FAKE_PRS_JSON='[]'
  FAKE_BLOCKED_BY=0
  FAKE_DEPS_JSON='[]'
  FAKE_WORKTREE_LIST="worktree $MAIN
HEAD abc
branch refs/heads/main
"
  FAKE_GH_FAILS_ON="" FAKE_GH_WARN=""
  FAKE_GH_FAILS="" FAKE_WORKTREE_ADD_FAILS="" FAKE_FETCH_FAILS="" FAKE_MIX_FAILS=""
  export FAKE_ISSUE_JSON FAKE_PRS_JSON FAKE_BLOCKED_BY FAKE_DEPS_JSON FAKE_WORKTREE_LIST \
    FAKE_GH_FAILS FAKE_GH_FAILS_ON FAKE_GH_WARN FAKE_WORKTREE_ADD_FAILS FAKE_FETCH_FAILS FAKE_MIX_FAILS
}

# Worktree-mode run: always from a directory that is neither the script's repo nor the
# main checkout, with the fake git (plus gh and mix) first on PATH.
pf() { ( cd "$WORKDIR/elsewhere" && env PATH="$FAKEGIT:$STUBDIR:$PATH" "$HERE/ticket-preflight" "$@" ); }

reset_world
test_run "a non-numeric issue is a usage error (no JSON)" 2 "" "need an issue number" pf abc

reset_world
test_run "a leading-zero issue number is a usage error (would split worktree vs JSON)" 2 "" "need an issue number" pf 0538

reset_world
test_run "--check-only with --in-place is a usage error" 2 "" "exclusive" pf 538 --check-only --in-place

reset_world
test_run "--expect-worktree without --in-place is a usage error" 2 "" "only makes sense with --in-place" pf 538 --expect-worktree /x

reset_world
test_run "--in-place without --expect-worktree is a usage error" 2 "" "needs --expect-worktree" pf 538 --in-place

reset_world
FAKE_ISSUE_JSON='{"state":"OPEN","title":"t","labels":[{"name":"needs-triage"}]}'
test_run "no ready-for-agent label is refused as not_ready" 1 '.ok == false and .reason == "not_ready" and .issue == 538' "ready-for-agent" pf 538
test_called no "a refusal creates nothing" "worktree add"

reset_world
FAKE_ISSUE_JSON='{"state":"CLOSED","title":"t","labels":[{"name":"ready-for-agent"}]}'
test_run "a closed issue is refused as closed" 1 '.reason == "closed"' "not open" pf 538

reset_world
FAKE_PRS_JSON='[{"number":77,"body":"Closes #538","closingIssuesReferences":[]}]'
test_run "an open PR closing it is refused as open_pr, naming the PR" 1 '.reason == "open_pr" and (.message | contains("#77"))' "#77" pf 538
test_called no "a refusal creates nothing" "worktree add"

reset_world
FAKE_BLOCKED_BY=1
FAKE_DEPS_JSON='[{"number":9,"state":"open"},{"number":8,"state":"closed"}]'
test_run "an open native blocker is refused as blocked, naming it" 1 '.reason == "blocked" and (.message | contains("#9")) and ((.message | contains("#8")) | not)' "#9" pf 538
test_called no "a refusal creates nothing" "worktree add"

reset_world
FAKE_GH_FAILS=1
test_run "a failing gh is a tool error (exit 3) with JSON, not a refusal" 3 '.ok == false and .reason == "gh_failed"' "auth login" pf 538

reset_world
test_run "the happy path creates the worktree and reports it" 0 \
  ".ok == true and .issue == 538 and .mode == \"worktree\" and .existing == false and .worktree == \"$WT\" and .branch == \"ticket-538-bin-ticket-preflight-refuse-an-unready-t\"" \
  "ready, worktree" pf 538
test_called yes "fetches main first" "git -C $MAIN fetch origin main"
test_called yes "adds the worktree from origin/main without tracking, via the main checkout" \
  "git -C $MAIN worktree add --no-track -b ticket-538-bin-ticket-preflight-refuse-an-unready-t $WT origin/main"
test_called yes "runs mix deps.get at the worktree's root" "mix: in ticket-538"
test_called yes "the repository is resolved from the script's own checkout, not the caller's cwd" "gh-cwd: $(dirname "$HERE")"
test_called yes "resolved the main checkout from the script's repo, not the caller's cwd" "-C $(dirname "$HERE") rev-parse"
expect no "subprocess chatter (git fetch progress, mix output) never reaches stderr" \
  test "$(printf '%s' "$T_ERR" | grep -c 'Enumerating objects\|Resolving Hex')" -gt 0
eq "1" "  ...stderr is one human line" "$(printf '%s\n' "$T_ERR" | grep -c .)"

reset_world
mkdir -p "$WT/deps"
FAKE_WORKTREE_LIST="worktree $MAIN
branch refs/heads/main

worktree $WT
HEAD def
branch refs/heads/ticket-538-earlier
"
FAKE_ISSUE_JSON='{"state":"OPEN","title":"t","labels":[]}'
test_run "an existing worktree is reported, not rebuilt (even with a PR open or label gone)" 0 \
  ".ok == true and .existing == true and .worktree == \"$WT\" and .branch == \"ticket-538-earlier\"" \
  "already exists" pf 538
test_called no "an idempotent re-run asks gh nothing" "gh "
test_called no "an idempotent re-run creates nothing" "worktree add"
test_called no "an idempotent re-run with deps present runs no mix" "mix "

mkdir -p "$WT" && rm -rf "$WT/deps"
test_run "an existing worktree missing deps/ gets deps.get finished" 0 '.existing == true' "already exists" pf 538
test_called yes "deps.get ran in the existing worktree" "mix: in ticket-538"
FAKE_MIX_FAILS=1
test_run "...and a failing deps.get there is a tool error that shows the tail" 3 '.reason == "deps_failed"' "could not reach hex.pm" pf 538

reset_world
mkdir -p "$WT/deps"
FAKE_WORKTREE_LIST="worktree $MAIN
branch refs/heads/main

worktree $WT
HEAD def
detached
"
test_run "a detached-HEAD worktree is existing with an empty branch" 0 '.existing == true and .branch == ""' "already exists" pf 538

reset_world
FAKE_WORKTREE_LIST="worktree $MAIN
branch refs/heads/main

worktree $WT
HEAD def
branch refs/heads/ticket-538-gone
prunable gitdir file points to non-existent location
"
test_run "a registered-but-missing (prunable) worktree is not 'existing': it is rebuilt" 0 '.existing == false' "ready, worktree" pf 538

reset_world
FAKE_GH_FAILS_ON="pr list"
test_run "gh failing only on the second call is a tool error, not a pass" 3 '.reason == "gh_failed"' "HTTP 502" pf 538
test_called no "and creates nothing" "worktree add"

reset_world
FAKE_GH_FAILS_ON="api repos/SBLabsCo/ash_swift/issues/538"
test_run "gh failing only on the blocker lookup is a tool error, never a pass" 3 '.reason == "gh_failed"' "HTTP 502" pf 538

reset_world
FAKE_GH_WARN="A new release of gh is available: 2.99 -> 3.0"
test_run "a gh stderr warning on success neither refuses nor errors" 0 '.ok == true and .existing == false' "" pf 538

reset_world
FAKE_WORKTREE_ADD_FAILS=1
test_run "a failing worktree add is a tool error" 3 '.reason == "git_failed"' "worktree add failed" pf 538

reset_world
FAKE_FETCH_FAILS=1
test_run "a failing fetch is a tool error, shows the tail, and adds nothing" 3 '.reason == "git_failed"' "could not read from remote" pf 538
test_called no "no worktree after a failed fetch" "worktree add"

reset_world
FAKE_MIX_FAILS=1
test_run "a failing deps.get is a tool error that says the worktree exists" 3 '.reason == "deps_failed" and (.message | contains("worktree was created"))' "mix deps.get failed" pf 538

echo
echo "bin/ticket-preflight --check-only (stub gh, no git)"

# No git on this PATH at all beyond the real one: the fake is simply not put first, and
# $TEST_CALLS shows none was made. A --check-only run must work outside any repository.
chk() { ( cd "$WORKDIR/elsewhere" && env PATH="$STUBDIR:$PATH" "$HERE/ticket-preflight" "$@" ); }

reset_world
test_run "a ready ticket reports ok with the branch name it would get" 0 \
  '.ok == true and .mode == "check-only" and .issue == 538 and .branch == "ticket-538-bin-ticket-preflight-refuse-an-unready-t" and (has("worktree") | not)' \
  "ready" chk 538 --check-only
test_called no "it asked no git anything" "git "
test_called no "it ran no mix" "mix "

reset_world
FAKE_PRS_JSON='[{"number":77,"body":"Closes #538","closingIssuesReferences":[]}]'
test_run "an open PR refuses a check-only run too (the workflow would otherwise spend an agent)" 1 '.reason == "open_pr"' "#77" chk 538 --check-only

echo
echo "bin/ticket-preflight --in-place (real git, stub gh/mix)"

# A throwaway origin with one commit on main, a clone of it as the
# "main checkout", and per scenario a fresh linked worktree on a harness-style
# placeholder branch — what an isolated implementer starts in.
mkdir -p "$WORKDIR/real"
test_git_origin "$WORKDIR/real"
ORIGIN="$TEST_ORIGIN" RMAIN="$TEST_CLONE"

AGENT_SEQ=0
new_agent_worktree() {
  AGENT_SEQ=$((AGENT_SEQ + 1))
  AGENT="$RMAIN/.claude/worktrees/agent-$AGENT_SEQ"
  git -C "$RMAIN" worktree add -q -b "worktree-agent-$AGENT_SEQ" "$AGENT" origin/main
}
branch_of() { git -C "$1" symbolic-ref --short HEAD; }
inplace() { ( cd "$1" && shift && env PATH="$STUBDIR:$PATH" "$HERE/ticket-preflight" "$@" ); }
EXPECTED_BRANCH="ticket-538-bin-ticket-preflight-refuse-an-unready-t"

reset_world
new_agent_worktree
test_run "inside a linked worktree it cuts the ticket branch from origin/main there" 0 \
  ".ok == true and .mode == \"in-place\" and .existing == false and .worktree == \"$AGENT\" and .branch == \"$EXPECTED_BRANCH\"" \
  "ready, branch" inplace "$AGENT" 538 --in-place --expect-worktree "$AGENT"
eq "$EXPECTED_BRANCH" "  ...the worktree is now on that branch" "$(branch_of "$AGENT")"
eq "$(git -C "$RMAIN" rev-parse origin/main)" "  ...cut from origin/main" "$(git -C "$AGENT" rev-parse HEAD)"
eq "" "  ...with no upstream tracking" "$(git -C "$AGENT" config --get "branch.$EXPECTED_BRANCH.remote" || true)"
eq "main" "  ...and the main checkout's own branch is untouched" "$(branch_of "$RMAIN")"
test_called yes "  ...deps were fetched at this worktree's root" "mix: in agent-$AGENT_SEQ"
eq "1" "  ...stderr is one human line, no subprocess chatter" "$(printf '%s\n' "$T_ERR" | grep -c .)"

test_run "re-running on that worktree is idempotent: existing, no gh, branch kept" 0 \
  ".ok == true and .existing == true and .branch == \"$EXPECTED_BRANCH\"" "already on" \
  inplace "$AGENT" 538 --in-place --expect-worktree "$AGENT"
test_calls_reset
inplace "$AGENT" 538 --in-place --expect-worktree "$AGENT" >/dev/null 2>&1
test_called no "  ...and asks gh nothing" "gh "

reset_world
new_agent_worktree
FAKE_ISSUE_JSON='{"state":"OPEN","title":"t","labels":[]}'
test_run "an unready ticket is refused in place and the branch is left alone" 1 '.reason == "not_ready"' "ready-for-agent" \
  inplace "$AGENT" 538 --in-place --expect-worktree "$AGENT"
eq "worktree-agent-$AGENT_SEQ" "  ...still on the harness branch" "$(branch_of "$AGENT")"

reset_world
test_run "from the main checkout it refuses outright (never writes there)" 1 '.reason == "not_linked_worktree"' "main checkout" \
  inplace "$RMAIN" 538 --in-place --expect-worktree "$RMAIN"
eq "main" "  ...the main checkout is still on main" "$(branch_of "$RMAIN")"
test_called no "  ...no gh was spent" "gh "

reset_world
new_agent_worktree
test_run "--expect-worktree naming another worktree is refused before any write" 1 '.reason == "wrong_worktree"' "--expect-worktree" \
  inplace "$AGENT" 538 --in-place --expect-worktree "$RMAIN/.claude/worktrees/agent-1"
eq "worktree-agent-$AGENT_SEQ" "  ...still on the harness branch" "$(branch_of "$AGENT")"

reset_world
new_agent_worktree
git -C "$AGENT" checkout -q -b ticket-999-someone-elses
test_run "another ticket's branch is refused, not branched over" 1 '.reason == "foreign_ticket_branch"' "ticket-999-someone-elses" \
  inplace "$AGENT" 538 --in-place --expect-worktree "$AGENT"
eq "ticket-999-someone-elses" "  ...still on that branch" "$(branch_of "$AGENT")"

reset_world
test_run "outside any git checkout it refuses as not_linked_worktree (exit 1, not a tool error)" 1 '.reason == "not_linked_worktree"' "not inside a git checkout" \
  inplace "$WORKDIR/elsewhere" 538 --in-place --expect-worktree "$WORKDIR/elsewhere"

reset_world
new_agent_worktree
echo scratch > "$AGENT/uncommitted.txt"
test_run "uncommitted changes are refused" 1 '.reason == "dirty_worktree"' "uncommitted" inplace "$AGENT" 538 --in-place --expect-worktree "$AGENT"
rm "$AGENT/uncommitted.txt"

reset_world
new_agent_worktree
git -C "$AGENT" -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m "local work"
test_run "HEAD commits not on origin/main are refused (they would be left behind)" 1 '.reason == "unpushed_commits"' "not on origin/main" \
  inplace "$AGENT" 538 --in-place --expect-worktree "$AGENT"
eq "worktree-agent-$AGENT_SEQ" "  ...still on the harness branch" "$(branch_of "$AGENT")"

reset_world
new_agent_worktree
test_run "a ticket branch that already exists elsewhere is a tool error, with the reason, and moves nothing" 3 \
  '.reason == "git_failed"' "already exists" inplace "$AGENT" 538 --in-place --expect-worktree "$AGENT"
eq "worktree-agent-$AGENT_SEQ" "  ...still on the harness branch" "$(branch_of "$AGENT")"

reset_world
new_agent_worktree
FAKE_ISSUE_JSON='{"state":"OPEN","title":"A different title","labels":[{"name":"ready-for-agent"}]}'
FAKE_MIX_FAILS=1
test_run "a failing deps.get is a tool error that says the branch was created, with the tail" 3 \
  '.reason == "deps_failed" and (.message | contains("branch was created"))' "could not reach hex.pm" \
  inplace "$AGENT" 538 --in-place --expect-worktree "$AGENT"

reset_world
new_agent_worktree
FAKE_GH_FAILS=1
test_run "a gh failure in place is exit 3 and the branch is left alone" 3 '.reason == "gh_failed"' "auth login" inplace "$AGENT" 538 --in-place --expect-worktree "$AGENT"
eq "worktree-agent-$AGENT_SEQ" "  ...still on the harness branch" "$(branch_of "$AGENT")"

test_summary "ticket-preflight.test.sh"
