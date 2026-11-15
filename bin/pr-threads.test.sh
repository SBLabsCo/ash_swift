#!/usr/bin/env bash
#
# Test for bin/pr-threads and bin/pr-threads-lib.sh (ported from SBLabsCo/SwingClips#537).
#
#     bin/pr-threads.test.sh
#
# Two layers: the lib's pure functions and jq program run against fixture JSON, then
# bin/pr-threads itself runs end to end against a stub `gh` placed first on PATH — no
# network, no real repository, never the real gh.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=./test-lib.sh
. "$HERE/test-lib.sh"
# shellcheck source=./pr-threads-lib.sh
. "$HERE/pr-threads-lib.sh"

echo "argument validators"
expect yes "a GraphQL node id is a valid thread id" pr_threads_valid_thread_id "PRRT_kwDOAbc-123_x="
expect no "a thread id with a space is refused" pr_threads_valid_thread_id "PRRT bad"
expect no "a thread id with shell metacharacters is refused" pr_threads_valid_thread_id 'PRRT;rm'

echo
echo "unresolved-thread shaping (jq)"

# Two pages: page 1 holds a resolved thread, an unresolved one with a reply, and an
# outdated thread (line null) by a deleted author; page 2 holds one more unresolved.
PAGES='[
 {"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[
  {"id":"T_resolved","isResolved":true,"isOutdated":false,"path":"a.ex","line":1,"originalLine":1,
   "comments":{"nodes":[{"body":"old","url":"u0","author":{"login":"bot"}}]}},
  {"id":"T_open","isResolved":false,"isOutdated":false,"path":"b.ex","line":42,"originalLine":40,
   "comments":{"nodes":[{"body":"fix this","url":"u1","author":{"login":"claude"}},
                        {"body":"why?","url":"u1b","author":{"login":"scott"}}]}},
  {"id":"T_moved","isResolved":false,"isOutdated":true,"path":"c.ex","line":null,"originalLine":7,
   "comments":{"nodes":[{"body":"nit","url":"u2","author":null}]}}
 ]}}}}},
 {"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[
  {"id":"T_page2","isResolved":false,"isOutdated":false,"path":"d.ex","line":3,"originalLine":3,
   "comments":{"nodes":[{"body":"p2","url":"u3","author":{"login":"claude"}}]}}
 ]}}}}}
]'

shaped="$(printf '%s' "$PAGES" | jq -c "$PR_THREADS_UNRESOLVED_JQ")"
eq '["T_open","T_moved","T_page2"]' \
  "resolved threads are dropped; pages are concatenated in order" "$(jq -c 'map(.id)' <<<"$shaped")"
eq '{"id":"T_open","path":"b.ex","outdated":false,"line":42,"author":"claude","body":"fix this","url":"u1","replies":[{"author":"scott","body":"why?"}]}' \
  "root comment becomes author/body/url; later comments become replies" \
  "$(jq -c '.[0]' <<<"$shaped")"
eq '7 null true' "an outdated thread falls back to originalLine; a ghost author is null" \
  "$(jq -r '.[1] | "\(.line) \(.author) \(.outdated)"' <<<"$shaped")"
eq '[]' "no unresolved threads is an empty array" \
  "$(printf '%s' '[{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}]' \
      | jq -c "$PR_THREADS_UNRESOLVED_JQ")"
eq '{"T_resolved":true,"T_open":false,"T_moved":false,"T_page2":false}' \
  "the state map covers every thread, resolved or not" \
  "$(printf '%s' "$PAGES" | jq -c "$PR_THREADS_STATE_JQ")"

echo
echo "bin/pr-threads end to end (stub gh)"

test_workdir
WORKDIR="$TEST_WORKDIR"
STUBDIR="$WORKDIR/stubs"

# A fake `gh`, driven by env vars set per scenario:
#   FAKE_GH_PAGES      — the body `gh api graphql --paginate --slurp` prints.
#   FAKE_GH_WARN       — text printed on stderr by every call, even successful ones.
#   FAKE_GH_FAIL_ON    — a substring; a graphql call whose arguments contain it exits 1
#                        (e.g. "addPullRequestReviewThreadReply", or "id=T_open").
# test_stub logs every invocation to $TEST_CALLS, so a scenario can assert which
# mutations ran, in what order.
test_stub "$STUBDIR" gh <<'GH_STUB'
#!/usr/bin/env bash
# FAKE_GH_WARN: a warning on stderr alongside a perfectly good, successful response.
[[ -z "${FAKE_GH_WARN:-}" ]] || echo "$FAKE_GH_WARN" >&2
if [[ "$1 $2" == "repo view" ]]; then
  printf '%s' "$FAKE_GH_REPO_JSON"
  exit 0
fi
if [[ "$1 $2" == "api graphql" ]]; then
  if [[ -n "${FAKE_GH_FAIL_ON:-}" && "$*" == *"$FAKE_GH_FAIL_ON"* ]]; then
    echo "gh: graphql failed" >&2
    exit 1
  fi
  printf '%s' "${FAKE_GH_PAGES:-}"
  exit 0
fi
echo "unstubbed gh invocation: $*" >&2
exit 99
GH_STUB

# expect_run <description> <wanted exit> <wanted stderr substring or ""> <args...>
# Runs bin/pr-threads against the stub gh; stdout lands in $OUT for the caller to assert on.
expect_run() {
  local what="$1" want_exit="$2" want_err="$3"; shift 3
  test_calls_reset
  test_run "$what" "$want_exit" "*" "$want_err" env PATH="$STUBDIR:$PATH" "$HERE/pr-threads" "$@"
  OUT="$T_OUT"
}

export FAKE_GH_PAGES="$PAGES" FAKE_GH_FAIL_ON=""
REPO_JSON='{"owner":{"login":"SBLabsCo"},"name":"ash_swift"}'
export FAKE_GH_REPO_JSON="$REPO_JSON"

expect_run "listing prints the unresolved threads as JSON" 0 "" 537
eq '["T_open","T_moved","T_page2"]' "  ...three threads, stdout is pure JSON" \
  "$(jq -c 'map(.id)' <<<"$OUT")"
eq "0" "  ...only a read happened (no mutation)" "$(test_calls_count mutation)"

FAKE_GH_WARN="A new release of gh is available: 2.99 -> 3.0" expect_run "a gh stderr warning on a successful call never corrupts the JSON" 0 "" 537
eq '["T_open","T_moved","T_page2"]' "  ...stdout is still pure JSON" "$(jq -c 'map(.id)' <<<"$OUT")"

expect_run "no PR argument is a usage error" 2 "missing <pr>"
expect_run "a non-numeric PR is a usage error" 2 "not a pull request number" abc
expect_run "--resolve with no ids is a usage error" 2 "needs at least one thread id" 537 --resolve
expect_run "--reply without --resolve is a usage error" 2 "--reply only makes sense" 537 --reply "x"
expect_run "an empty reply is a usage error" 2 "text is empty" 537 --resolve T1 --reply "  "
expect_run "a malformed thread id is a usage error" 2 "not a thread id" 537 --resolve 'T;1'
expect_run "an unknown flag is a usage error" 2 "unknown argument" 537 --frobnicate
eq "" "usage errors never reached gh" "$(cat "$TEST_CALLS")"
eq "" "usage errors print nothing on stdout" "$OUT"

expect_run "--help prints the header and exits 0" 0 "" --help
header_ok() { [[ "$OUT" == *"list and resolve"* && "$OUT" == *"Exit codes"* ]]; }
expect yes "  ...the full header, through the exit codes" header_ok

expect_run "--resolve resolves each id and reports it" 0 "" 537 --resolve T_open T_moved
eq '[{"id":"T_open","replied":false,"resolved":true,"already":false},{"id":"T_moved","replied":false,"resolved":true,"already":false}]' \
  "  ...JSON result per id" "$(jq -c '.' <<<"$OUT")"
eq "2 0" "  ...two resolve mutations, no reply" \
  "$(test_calls_count resolveReviewThread) $(test_calls_count addPullRequestReviewThreadReply)"

expect_run "--reply posts the reply before resolving" 0 "" 537 --resolve T_open --reply "Declined: intentional."
eq "addPullRequestReviewThreadReply resolveReviewThread" "  ...reply then resolve, in that order" \
  "$(grep -o 'addPullRequestReviewThreadReply\|resolveReviewThread' "$TEST_CALLS" | tr '\n' ' ' | sed 's/ $//')"
eq "1" "  ...the rationale is passed as the body" "$(test_calls_count 'body=Declined: intentional.')"
eq '[{"id":"T_open","replied":true,"resolved":true,"already":false}]' \
  "  ...result reports replied and resolved" "$(jq -c '.' <<<"$OUT")"

expect_run "a repeated id is handled once (the rationale is not posted twice)" 0 "" \
  537 --resolve T_open T_open --reply "once"
eq "1 1" "  ...one reply, one resolve" \
  "$(test_calls_count addPullRequestReviewThreadReply) $(test_calls_count resolveReviewThread)"

expect_run "an id that is not this PR's thread is refused (exit 1, a domain no) before any mutation" 1 \
  "T_other is not a review thread of PR #537" 537 --resolve T_open T_other
eq "0" "  ...nothing was mutated, not even the valid id" "$(test_calls_count mutation)"
eq "unknown_thread" "  ...and stdout says why, as JSON" "$(jq -r '.reason' <<<"$OUT")"

expect_run "an already-resolved id is reported, not re-resolved or replied to" 0 "" \
  537 --resolve T_resolved --reply "late rationale"
eq '[{"id":"T_resolved","replied":false,"resolved":true,"already":true}]' \
  "  ...already:true, nothing posted" "$(jq -c '.' <<<"$OUT")"
eq "0" "  ...no mutation ran" "$(test_calls_count mutation)"

FAKE_GH_FAIL_ON="addPullRequestReviewThreadReply"
expect_run "a failed reply leaves the thread unresolved and exits 3" 3 "leaving it unresolved" \
  537 --resolve T_open --reply "why"
eq "0" "  ...no resolve mutation was attempted" "$(test_calls_count resolveReviewThread)"
eq '[{"id":"T_open","replied":false,"resolved":false,"already":false}]' \
  "  ...result says so" "$(jq -c '.' <<<"$OUT")"

FAKE_GH_FAIL_ON="resolveReviewThread"
expect_run "a failed resolve exits 3 and is reported" 3 "resolving T_open failed" 537 --resolve T_open
eq '[{"id":"T_open","replied":false,"resolved":false,"already":false}]' \
  "  ...result says so" "$(jq -c '.' <<<"$OUT")"

FAKE_GH_FAIL_ON="id=T_open"
expect_run "one id failing does not stop the remaining ids" 3 "resolving T_open failed" \
  537 --resolve T_open T_moved
eq '[{"id":"T_open","replied":false,"resolved":false,"already":false},{"id":"T_moved","replied":false,"resolved":true,"already":false}]' \
  "  ...per-id results: T_open failed, T_moved resolved" "$(jq -c '.' <<<"$OUT")"
eq "1" "  ...T_moved's resolve mutation still ran" "$(test_calls_count 'id=T_moved')"

FAKE_GH_FAIL_ON="reviewThreads"
expect_run "a failing list call exits 3 with a diagnostic" 3 "gh api graphql failed" 537
eq '{"ok":false,"pr":537,"reason":"gh_failed"}' "  ...and stdout carries the failure object, not nothing" \
  "$(jq -c '{ok, pr, reason}' <<<"$OUT")"
FAKE_GH_FAIL_ON=""

FAKE_GH_REPO_JSON='{}'
expect_run "a repo view of the wrong shape exits 3 as bad_response" 3 "could not determine the repository" 537
eq "bad_response" "  ...and stdout carries the failure object" "$(jq -r '.reason' <<<"$OUT")"
FAKE_GH_REPO_JSON="$REPO_JSON"

FAKE_GH_PAGES='not json'
expect_run "an unparseable response exits 3 with the script's own diagnostic" 3 \
  "unparseable output" 537
eq "bad_response" "  ...and stdout carries the failure object" "$(jq -r '.reason' <<<"$OUT")"

FAKE_GH_PAGES='{"data":{"repository":null}}'
expect_run "a response of the wrong shape exits 3 as bad_response" 3 "unexpected shape" 537
eq "bad_response" "  ...and stdout carries the failure object" "$(jq -r '.reason' <<<"$OUT")"

test_summary "pr-threads.test.sh"
