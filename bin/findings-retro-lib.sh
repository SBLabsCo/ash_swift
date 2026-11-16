# bin/findings-retro-lib.sh — the pure parts of bin/findings-retro: choosing which merged
# PRs a retro reads, and folding their run records into the report the findings-retro skill
# turns into guidance edits. Side-effecting `gh` calls stay in bin/findings-retro; this is
# what bin/findings-retro.test.sh exercises directly. Sourced, not executable; needs `jq`.

# shellcheck source=./after-merge-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/after-merge-lib.sh"

# A retro's own PR is titled with this prefix; the newest merged one is where the next
# retro's default window starts.
FINDINGS_RETRO_TITLE_PREFIX='Findings retro'

# findings_retro_window <merged-prs-json> <since|last> — the candidate PRs, newest first,
# from `gh pr list --state merged --json number,title,mergedAt`:
#   mode since: every PR merged after the newest merged retro PR, retro PRs themselves
#               excluded; {since: <that mergedAt>, retro_pr: <n>}. With no retro yet it
#               falls back to `last` (since: null).
#   mode last:  every non-retro PR, newest first — the caller reads records down the list
#               until it has <last-n> of them.
# Output: {mode, since, retro_pr, candidates: [<pr numbers>]}.
findings_retro_window() {
  jq -c --arg mode "$2" --arg pre "$FINDINGS_RETRO_TITLE_PREFIX" '
    def is_retro: (.title // "") | startswith($pre);
    (sort_by(.mergedAt) | reverse) as $all
    | ([$all[] | select(is_retro)] | first) as $retro
    | [$all[] | select(is_retro | not)] as $work
    | if $mode == "since" and $retro != null then
        { mode: "since", since: $retro.mergedAt, retro_pr: $retro.number,
          candidates: [$work[] | select(.mergedAt > $retro.mergedAt) | .number] }
      else
        { mode: "last", since: null, retro_pr: ($retro.number // null), candidates: [$work[].number] }
      end' <<<"$1"
}

# jq program: [run records] -> the retro report. Needs `--argjson min` (how many distinct
# PRs make a category recurring). A v1 record's findings carry no category or problem: they
# are counted under `uncategorized`, never grouped. A v2 finding the lens could not
# categorise is `uncategorized` too, and likewise never recurring.
FINDINGS_RETRO_REPORT_JQ='
  def findings_of($r):
    ($r.declined // [] | map(select(.id != null) | {key: (.id | tostring), value: .rationale}) | from_entries) as $why
    | [ ($r.findings // [])[]
        | { pr: $r.pr, issue: $r.issue, id, source, severity, where, outcome,
            category: (if $r.v >= 2 then (.category // "uncategorized") else "uncategorized" end),
            problem: (.problem // null),
            rationale: (if .outcome == "declined" then $why[(.id | tostring)] else null end),
            v1: ($r.v < 2) } ];
  def tally(f): group_by(f) | map({key: (.[0] | f), value: length}) | from_entries;
  def group($fs):
    $fs | group_by(.category)
    | map({ category: .[0].category,
            prs: (map(.pr) | unique),
            lenses: tally(.source),
            severities: tally(.severity),
            outcomes: tally(.outcome),
            findings: map(del(.category, .v1)) })
    | map(. + {pr_count: (.prs | length)})
    | sort_by(-.pr_count, -(.findings | length), .category);
  . as $records
  | [ $records[] as $r | findings_of($r)[] ] as $all
  | [ $all[] | select(.v1 | not) | select(.category != "uncategorized") ] as $cat
  | { records: [ $records[] | { pr, issue, v, outcome, findings: ((.findings // []) | length) } ],
      categories: (group($cat) | map(. + {recurring: (.pr_count >= $min)})),
      declined_recurring: (group([ $cat[] | select(.outcome == "declined") ]) | map(select(.pr_count >= $min))),
      uncategorized: { count: ([ $all[] | select(.category == "uncategorized") ] | length),
                       v1_prs: ([ $records[] | select(.v < 2) | .pr ] | unique) },
      followups: [ $records[] as $r | ($r.followups // [])[] | { pr: $r.pr, title } ] }'

# findings_retro_report <records-json-array> <min-prs> — FINDINGS_RETRO_REPORT_JQ applied.
findings_retro_report() {
  jq -c --argjson min "$2" "$FINDINGS_RETRO_REPORT_JQ" <<<"$1"
}

# findings_retro_open_followups <issues-json> <prs-json-array> — the open issues (from
# `gh issue list --json number,title,body`) that bin/after-merge filed from these PRs'
# follow-ups, recognised by its marker line: [{number, title, pr}].
findings_retro_open_followups() {
  jq -c --argjson prs "$2" --arg pre "$(after_merge_marker '')" '
    [ .[] as $i
      | ($i.body // "") as $b
      | $prs[] as $pr
      | select($b | test(($pre | gsub("(?<c>[^A-Za-z0-9 ])"; "\\\(.c)")) + ($pr | tostring) + "(?![0-9])"))
      | { number: $i.number, title: $i.title, pr: $pr } ]
    | unique_by(.number)' <<<"$1"
}
