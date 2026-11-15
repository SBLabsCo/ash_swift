#!/usr/bin/env bash
#
# Test for bin/pr-record and bin/pr-record-lib.sh (ported from SBLabsCo/SwingClips#543).
#
#     bin/pr-record.test.sh
#
# The lib's pure functions run against fixture JSON, then bin/pr-record itself runs end
# to end against a stub `gh` placed first on PATH — no network, never the real gh.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=./test-lib.sh
. "$HERE/test-lib.sh"
# shellcheck source=./pr-record-lib.sh
. "$HERE/pr-record-lib.sh"

echo "record validation"
expect yes "a v1 record about this PR is valid" pr_record_valid 7 '{"v":1,"issue":543,"pr":7}'
expect no "another PR's record is refused" pr_record_valid 7 '{"v":1,"issue":543,"pr":8}'
expect no "an unversioned record is refused" pr_record_valid 7 '{"issue":543,"pr":7}'
expect no "a v2 record is refused (this tool writes v1)" pr_record_valid 7 '{"v":2,"issue":543,"pr":7}'
expect no "a record without an issue is refused" pr_record_valid 7 '{"v":1,"pr":7}'
expect no "a non-object is refused" pr_record_valid 7 '[1]'

echo
echo "comment body"
LINE="$(pr_record_line '{"v":1,"issue":543,"pr":7,"reason":"a --> b"}')"
GT_ESCAPED='\'u003e   # a backslash then u003e: the JSON escape for ">"
eq '<!-- ash-swift-run-record: {"v":1,"issue":543,"pr":7,"reason":"a --'"$GT_ESCAPED"' b"} -->' \
  "the record is one line and a string cannot close the comment early" "$LINE"
eq 'a --> b' "  ...and the escaped line decodes to the original text" \
  "$(pr_record_matching "$(jq -cn --arg b "$LINE" '[{id:1,body:$b,user:{login:"u"},author_association:"OWNER"}]')" 7 | jq -r '.[0].record.reason')"

echo
echo "picking records out of comments"
COMMENTS="$(jq -cn --arg a '<!-- ash-swift-run-record: {"v":1,"issue":543,"pr":7,"n":1} -->' \
                   --arg b '<!-- ash-swift-run-record: {"v":1,"issue":543,"pr":7,"n":2} -->' \
                   --arg c 'see <!-- ash-swift-run-record: {"v":1,"issue":543,"pr":7,"n":3} --> quoted' \
                   --arg d '<!-- ash-swift-run-record: {"v":2,"issue":543,"pr":7,"n":4} -->' \
                   --arg e '<!-- ash-swift-run-record: {"v":1,"issue":543,"pr":8,"n":6} -->' '[
  {id:1,body:$a,user:{login:"scott"},author_association:"OWNER"},
  {id:2,body:$b,user:{login:"drive-by"},author_association:"NONE"},
  {id:3,body:$c,user:{login:"scott"},author_association:"OWNER"},
  {id:4,body:$d,user:{login:"scott"},author_association:"OWNER"},
  {id:5,body:"unrelated",user:{login:"scott"},author_association:"OWNER"},
  {id:6,body:$e,user:{login:"scott"},author_association:"OWNER"}]')"
MATCHING="$(pr_record_matching "$COMMENTS" 7)"
eq '[1,2]' "only whole-body v1 records for this PR count (quoted, v2, other-PR and unrelated comments do not)" "$(jq -c 'map(.id)' <<<"$MATCHING")"
eq '1' "the caller's own record is found by login" "$(pr_record_latest_own "$MATCHING" scott | jq '.id')"
eq 'null' "no own record is null" "$(pr_record_latest_own "$MATCHING" nobody)"
eq '1' "a reader trusts the OWNER's record, not the drive-by's later one" "$(pr_record_latest_trusted "$MATCHING" | jq '.id')"
eq 'null' "no records is null" "$(pr_record_latest_trusted '[]')"

echo
echo "bin/pr-record end to end (stub gh)"

test_workdir
STUBDIR="$TEST_WORKDIR/stubs"

# FAKE_COMMENTS: the paginated, slurped comments response (array of pages).
# FAKE_GH_FAIL_ON: a substring; a call whose arguments contain it exits 1.
test_stub "$STUBDIR" gh <<'GH_STUB'
#!/usr/bin/env bash
if [[ -n "${FAKE_GH_FAIL_ON:-}" && "$*" == *"$FAKE_GH_FAIL_ON"* ]]; then echo "gh: failed" >&2; exit 1; fi
case "$1 $2" in
  "repo view") printf '%s' '{"owner":{"login":"o"},"name":"r"}' ;;
  "api user") echo scott ;;
  "api repos/o/r/issues/7/comments") printf '%s' "${FAKE_COMMENTS:-[[]]}" ;;
  "api -X")
    if [[ "$3" == POST ]]; then echo '{"id":900}'; else echo '{"id":'"${4##*/}"'}'; fi ;;
  *) echo "unstubbed gh invocation: $*" >&2; exit 99 ;;
esac
GH_STUB

expect_run() {
  local what="$1" want_exit="$2" want_err="$3"; shift 3
  test_calls_reset
  test_run "$what" "$want_exit" "*" "$want_err" env PATH="$STUBDIR:$PATH" "$HERE/pr-record" "$@"
  OUT="$T_OUT"
}

RECORD="$TEST_WORKDIR/record.json"
echo '{"v":1,"issue":543,"pr":7,"outcome":"merge-ready"}' > "$RECORD"
export FAKE_GH_FAIL_ON=""
export FAKE_COMMENTS='[[]]'

expect_run "a PR with no record gets a new comment" 0 "" 7 --file "$RECORD"
eq '{"ok":true,"pr":7,"comment_id":900,"action":"created"}' "  ...created" "$(jq -c . <<<"$OUT")"
eq "1 0" "  ...one POST, no PATCH" "$(test_calls_count 'POST') $(test_calls_count 'PATCH')"
test_called yes "  ...the body is the hidden one-line comment" 'body=<!-- ash-swift-run-record: {"v":1,"issue":543,"pr":7,"outcome":"merge-ready"} -->'

export FAKE_COMMENTS="$(jq -cn --arg b '<!-- ash-swift-run-record: {"v":1,"issue":543,"pr":7,"outcome":"escalated"} -->' \
  '[[{id:55,body:$b,user:{login:"scott"},author_association:"OWNER"}]]')"
expect_run "a re-run updates the caller's own record in place" 0 "" 7 --file "$RECORD"
eq '{"ok":true,"pr":7,"comment_id":55,"action":"updated"}' "  ...updated comment 55" "$(jq -c . <<<"$OUT")"
eq "0" "  ...nothing new was posted" "$(test_calls_count 'POST')"

echo '{"v":1,"issue":543,"pr":7,"outcome":"escalated"}' > "$RECORD"
expect_run "an unchanged record is left alone" 0 "" 7 --file "$RECORD"
eq '{"ok":true,"pr":7,"comment_id":55,"action":"unchanged"}' "  ...unchanged" "$(jq -c . <<<"$OUT")"
eq "0 0" "  ...no write at all" "$(test_calls_count 'POST') $(test_calls_count 'PATCH')"

export FAKE_COMMENTS="$(jq -cn --arg b '<!-- ash-swift-run-record: {"v":1,"issue":543,"pr":7,"n":1} -->' \
  '[[{id:56,body:$b,user:{login:"someone-else"},author_association:"MEMBER"}]]')"
echo '{"v":1,"issue":543,"pr":7,"n":2}' > "$RECORD"
expect_run "another author's record is not overwritten; the caller posts its own" 0 "" 7 --file "$RECORD"
eq "created" "  ...created" "$(jq -r .action <<<"$OUT")"

expect_run "--read prints the latest trusted record" 0 "" 7 --read
eq '{"v":1,"issue":543,"pr":7,"n":1}' "  ...as the bare record object" "$(jq -c . <<<"$OUT")"

export FAKE_COMMENTS='[[]]'
expect_run "--read on a PR with no record is a domain no" 1 "no run record" 7 --read
eq "no_record" "  ...with the reason on stdout" "$(jq -r .reason <<<"$OUT")"

echo '{"v":1,"issue":543,"pr":8}' > "$RECORD"
expect_run "a record naming another PR is refused before anything is posted" 1 "pr == 7" 7 --file "$RECORD"
eq "0" "  ...nothing was written" "$(test_calls_count 'POST')"
echo 'not json' > "$RECORD"
expect_run "a record that is not JSON is refused" 1 "not JSON" 7 --file "$RECORD"
jq -cn '{v:1,issue:543,pr:7,blob:("x" * 61000)}' > "$RECORD"
expect_run "a record too large for a comment is refused" 1 "trim the record" 7 --file "$RECORD"
eq "too_large" "  ...with the reason on stdout" "$(jq -r .reason <<<"$OUT")"

expect_run "no PR is a usage error" 2 "missing <pr>"
expect_run "a non-numeric PR is a usage error" 2 "not a pull request number" abc
expect_run "no mode is a usage error" 2 "say --file" 7
expect_run "a missing file is a usage error" 2 "is not a file" 7 --file "$TEST_WORKDIR/nope.json"
expect_run "an unknown flag is a usage error" 2 "unknown argument" 7 --frob
eq "" "  ...usage errors print nothing on stdout" "$OUT"
expect_run "--help prints the header" 0 "" --help
header_ok() { [[ "$OUT" == *"persist and read"* && "$OUT" == *"Exit codes"* ]]; }
expect yes "  ...through the exit codes" header_ok

echo '{"v":1,"issue":543,"pr":7}' > "$RECORD"
FAKE_GH_FAIL_ON="issues/7/comments" expect_run "a failing comments read exits 3 with the failure object" 3 "gh api" 7 --file "$RECORD"
eq "gh_failed" "  ...reason on stdout" "$(jq -r .reason <<<"$OUT")"

test_summary "pr-record.test.sh"
