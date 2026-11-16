#!/usr/bin/env bash
#
# Test for bin/findings-retro and bin/findings-retro-lib.sh (ported from SBLabsCo/SwingClips).
#
#     bin/findings-retro.test.sh
#
# The lib's pure functions run against fixture JSON, then bin/findings-retro itself runs end
# to end against a stub `gh` placed first on PATH — no network, never the real gh.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=./test-lib.sh
. "$HERE/test-lib.sh"
# shellcheck source=./findings-retro-lib.sh
. "$HERE/findings-retro-lib.sh"
# shellcheck source=./pr-record-lib.sh
. "$HERE/pr-record-lib.sh"

echo "the window"
MERGED='[
  {"number":10,"title":"Old work","mergedAt":"2026-11-01T00:00:00Z"},
  {"number":11,"title":"Findings retro: #88–#115","mergedAt":"2026-11-02T00:00:00Z"},
  {"number":12,"title":"New work","mergedAt":"2026-11-03T00:00:00Z"},
  {"number":14,"title":"Newer work","mergedAt":"2026-11-05T00:00:00Z"},
  {"number":13,"title":"Findings retro: an older one","mergedAt":"2026-10-01T00:00:00Z"}]'
W="$(findings_retro_window "$MERGED" since)"
eq '[14,12]' "since: the PRs merged after the newest retro PR, newest first" "$(jq -c .candidates <<<"$W")"
eq '"since" 11 "2026-11-02T00:00:00Z"' "...naming that retro PR and when it merged" "$(jq -r '"\"\(.mode)\" \(.retro_pr) \"\(.since)\""' <<<"$W")"
W="$(findings_retro_window "$MERGED" last)"
eq '[14,12,10]' "last: every non-retro PR, newest first" "$(jq -c .candidates <<<"$W")"
W="$(findings_retro_window '[{"number":1,"title":"a","mergedAt":"2026-01-01T00:00:00Z"}]' since)"
eq '"last" [1]' "since with no retro merged yet falls back to last" "$(jq -c '"\"\(.mode)\" \(.candidates|tojson)"' -r <<<"$W")"

echo
echo "the report"
f() { # <id> <source> <outcome> <category> — one v2 finding
  jq -cn --argjson id "$1" --arg s "$2" --arg o "$3" --arg c "$4" \
    '{id: $id, source: $s, severity: "nit", where: "x:1", outcome: $o, problem: "p\($id)", category: $c}'
}
RECORDS="$(jq -cn \
  --argjson a "$(f 0 reviewer fixed stale-doc-comment)" --argjson b "$(f 1 refactorer declined vacuous-test-assertion)" \
  --argjson c "$(f 0 refactorer fixed stale-doc-comment)" --argjson d "$(f 1 refactorer declined vacuous-test-assertion)" \
  --argjson e "$(f 2 reviewer fixed unhandled-edge-case)" --argjson g "$(f 3 security open uncategorized)" \
  --argjson h "$(f 4 reviewer fixed stale-doc-comment)" '[
  {v:2, issue:1, pr:101, outcome:"merge-ready", findings:[$a,$b], declined:[{id:1, rationale:"the assertion can fail", finding:"x"}],
   followups:[{title:"Implementer line", body:"b"}]},
  {v:2, issue:2, pr:102, outcome:"escalated", findings:[$c,$d,$e,$g,$h], declined:[{id:1, rationale:"pinned elsewhere", finding:"x"}, {rationale:"drive-loop decline, no id", finding:"y"}]},
  {v:1, issue:3, pr:103, outcome:"merge-ready", findings:[{id:0, source:"reviewer", severity:"nit", where:"y:2", outcome:"fixed"}]}]')"
REP="$(findings_retro_report "$RECORDS" 2)"
eq '["stale-doc-comment","vacuous-test-assertion","unhandled-edge-case"]' \
  "categories, most PRs then most findings first (uncategorized and v1 findings are never grouped)" "$(jq -c '[.categories[].category]' <<<"$REP")"
eq '[true,true,false]' "recurring = raised on at least --min-prs distinct PRs" "$(jq -c '[.categories[].recurring]' <<<"$REP")"
eq '{"refactorer":1,"reviewer":2}' "...with the lenses that raised it" "$(jq -c '.categories[0].lenses' <<<"$REP")"
eq '[101,102]' "...and the PRs it came from" "$(jq -c '.categories[0].prs' <<<"$REP")"
eq '"p0"' "...and each finding's one-line problem" "$(jq -c '.categories[0].findings[0].problem' <<<"$REP")"
eq '["vacuous-test-assertion"]' "a category declined on two PRs is reported as a recurring decline" "$(jq -c '[.declined_recurring[].category]' <<<"$REP")"
eq '["the assertion can fail","pinned elsewhere"]' "...each with the rationale it was declined for" "$(jq -c '[.declined_recurring[0].findings[].rationale]' <<<"$REP")"
eq '{"count":2,"v1_prs":[103]}' "a v1 finding and a v2 'uncategorized' one are only counted" "$(jq -c .uncategorized <<<"$REP")"
eq '[{"pr":101,"title":"Implementer line"}]' "the records' follow-ups are listed" "$(jq -c .followups <<<"$REP")"
eq '[101,102,103]' "every record is summarised" "$(jq -c '[.records[].pr]' <<<"$REP")"
eq '[]' "with --min-prs 3 nothing recurs" "$(findings_retro_report "$RECORDS" 3 | jq -c '[.categories[] | select(.recurring)]')"

echo
echo "open follow-up issues"
ISSUES="$(jq -cn --arg m816 "$(after_merge_marker 816)." --arg m8160 "$(after_merge_marker 8160)." '[
  {number:1, title:"a", body:("Body — with a dash.\n\n" + $m816)},
  {number:2, title:"b", body:$m8160},
  {number:3, title:"c", body:"Raised elsewhere"}]')"
eq '[{"number":1,"title":"a","pr":816}]' "an open issue carrying after-merge's marker for a window PR is found (not #8160's)" \
  "$(findings_retro_open_followups "$ISSUES" '[816,821]')"

echo
echo "bin/findings-retro end to end (stub gh)"

test_workdir
STUBDIR="$TEST_WORKDIR/stubs"
# FAKE_MERGED: the merged-PR list. FAKE_COMMENTS_<pr>: that PR's slurped comment pages.
# FAKE_GH_FAIL_ON: a substring; a call whose arguments contain it exits 1.
test_stub "$STUBDIR" gh <<'GH_STUB'
#!/usr/bin/env bash
if [[ -n "${FAKE_GH_FAIL_ON:-}" && "$*" == *"$FAKE_GH_FAIL_ON"* ]]; then echo "gh: failed" >&2; exit 1; fi
case "$1 $2" in
  "repo view") printf '%s' '{"owner":{"login":"o"},"name":"r"}' ;;
  "pr list") printf '%s' "${FAKE_MERGED:-[]}" ;;
  "issue list") printf '%s' "${FAKE_ISSUES:-[]}" ;;
  "api repos/o/r/issues/"*) n="${2#repos/o/r/issues/}"; n="${n%/comments}"; v="FAKE_COMMENTS_$n"; printf '%s' "${!v:-[[]]}" ;;
  *) echo "unstubbed gh invocation: $*" >&2; exit 99 ;;
esac
GH_STUB

comment() { # <record-json> — one slurped page holding the OWNER's record comment
  jq -cn --arg b "${PR_RECORD_PREFIX}$1${PR_RECORD_SUFFIX}" '[[{id:1,body:$b,user:{login:"scott"},author_association:"OWNER"}]]'
}
run() {
  local what="$1" want_exit="$2" want_err="$3"; shift 3
  test_calls_reset
  test_run "$what" "$want_exit" "*" "$want_err" env PATH="$STUBDIR:$PATH" "$HERE/findings-retro" "$@"
  OUT="$T_OUT"
}

export FAKE_GH_FAIL_ON=""
export FAKE_MERGED='[
  {"number":5,"title":"Findings retro: first","mergedAt":"2026-11-02T00:00:00Z"},
  {"number":6,"title":"Work A","mergedAt":"2026-11-03T00:00:00Z"},
  {"number":7,"title":"Docs only","mergedAt":"2026-11-04T00:00:00Z"},
  {"number":8,"title":"Work B","mergedAt":"2026-11-05T00:00:00Z"}]'
FAKE_COMMENTS_6="$(comment "$(jq -c '.[0] | .pr = 6' <<<"$RECORDS")")"
FAKE_COMMENTS_8="$(comment "$(jq -c '.[1] | .pr = 8' <<<"$RECORDS")")"
export FAKE_COMMENTS_6 FAKE_COMMENTS_8
export FAKE_ISSUES="$(jq -cn --arg b "$(after_merge_marker 6)." '[{number:40,title:"Implementer line",body:$b}]')"

run "the default window reads every PR merged since the last retro" 0 "read 2 run record(s)"
eq '{"mode":"since","since":"2026-11-02T00:00:00Z","retro_pr":5,"prs":[8,6]}' "  ...the window" "$(jq -c .window <<<"$OUT")"
eq '[{"pr":7,"reason":"no_record"}]' "  ...a PR without a record is skipped, not an error" "$(jq -c .skipped <<<"$OUT")"
eq '["stale-doc-comment","vacuous-test-assertion"]' "  ...the recurring categories" "$(jq -c '[.categories[] | select(.recurring) | .category]' <<<"$OUT")"
eq '[{"number":40,"title":"Implementer line","pr":6}]' "  ...and the follow-up issues still open" "$(jq -c .open_followup_issues <<<"$OUT")"
test_called no "  ...the retro PR itself is never read as work" "issues/5/comments"

run "--last 1 reads only the newest record" 0 "" --last 1
expect no "  ...and does not claim there is no retro PR when one was merged" grep -q "no merged retro PR" <<<"$T_ERR"
eq '[8]' "  ...#8" "$(jq -c .window.prs <<<"$OUT")"
test_called no "  ...and reads nothing past it" "issues/6/comments"

run "--prs reads exactly those PRs, without listing merged ones" 0 "" --prs 6
eq '[6]' "  ...#6" "$(jq -c .window.prs <<<"$OUT")"
test_called no "  ...no merged-PR list" "pr list"
run "--min-prs 3 makes nothing recur" 0 "" --min-prs 3
eq '[]' "  ...no recurring category" "$(jq -c '[.categories[] | select(.recurring)]' <<<"$OUT")"

run "no record in the window is a domain no" 1 "no merged PR" --prs 7
eq "no_records" "  ...with the reason on stdout" "$(jq -r .reason <<<"$OUT")"
FAKE_GH_FAIL_ON="pr list" run "a failing merged-PR list exits 3" 3 "gh pr list"
eq "gh_failed" "  ...reason on stdout" "$(jq -r .reason <<<"$OUT")"

run "--last needs a number" 2 "--last needs" --last x
run "--prs needs a list of numbers" 2 "--prs needs" --prs "6,x"
run "an unknown flag is a usage error" 2 "unknown argument" --frob
eq "" "  ...usage errors print nothing on stdout" "$OUT"
run "--help prints the header" 0 "" --help
header_ok() { [[ "$OUT" == *"run records"* && "$OUT" == *"Exit codes"* ]]; }
expect yes "  ...through the exit codes" header_ok

test_summary "findings-retro.test.sh"
