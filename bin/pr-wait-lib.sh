# bin/pr-wait-lib.sh — the pure parts of bin/pr-wait (ported from SBLabsCo/SwingClips#541): which
# workflows a PR's diff should trigger, the review-verdict footer parse, and the one jq
# program that turns the gathered facts into the answer. Sourced by bin/pr-wait and its
# tests; needs jq, awk and bash >= 5 (bin/cli-lib.sh guards that).

PR_WAIT_REVIEW_WORKFLOW="Claude PR review"

# pr_wait_workflow_triggers <workflows-dir> — one line per workflow that runs on
# `pull_request`: "<workflow name><TAB><glob>" per positive `paths:` entry, or
# "<name><TAB>*" when it has no usable path filter. The name is the `name:` key, else the
# file's path. Reads the checkout's own workflow files with a small awk, and every miss
# fails SAFE (toward over-expecting, which makes a PR not-ready, never falsely ready):
#   - understood: `pull_request:` blocks (any indent), `paths:` as a block list (items at
#     or below the key's indent) or a flow list `[a, b]`, quoted/commented items;
#   - `!negated` entries are skipped; `paths-ignore`, a filter with no positive glob, and
#     the inline forms `on: pull_request` / `on: [push, pull_request]` give `*`;
#   - a mention of `pull_request` (not `pull_request_target`) before `jobs:` with nothing
#     parsed gives `*`; comment lines are ignored.
pr_wait_workflow_triggers() {
  local f
  for f in "$1"/*.yml "$1"/*.yaml; do
    [[ -f "$f" ]] || continue
    awk -v fallback="$f" '
      function indent(s) { match(s, /^ */); return RLENGTH }
      function add(g) {
        gsub(/^[ \t]+|[ \t]+$/, "", g); sub(/[ \t]+#.*$/, "", g); gsub(/^["\047]|["\047]$/, "", g)
        if (g == "" || substr(g, 1, 1) == "!") return
        globs[++n] = g
      }
      /^[ \t]*#/ || /^[ \t]*$/ { next }
      {
        ind = indent($0)
        if (ind == 0 && $0 ~ /^name:/) { name = $0; sub(/^name:[ \t]*/, "", name); gsub(/[ \t]+#.*$/, "", name); gsub(/^["\047]|["\047]$/, "", name) }
        if (ind == 0 && $0 ~ /^jobs:/) injobs = 1
        if (inpr && ind <= pi) { inpr = 0; inpaths = 0 }
        if (inpaths && ind < pathsind) inpaths = 0
        if (inpaths && ind == pathsind && $0 !~ /^ *- /) inpaths = 0
        if (!injobs && $0 ~ /pull_request([^_A-Za-z]|$)/) haspr = 1
        if ($0 ~ /^ *pull_request:/) { inpr = 1; pi = ind; inpaths = 0; next }
        if (inpr) {
          if ($0 ~ /^ *paths:/) {
            inpaths = 1; pathsind = ind
            rest = $0; sub(/^ *paths:[ \t]*/, "", rest)
            if (rest ~ /^\[/) {
              gsub(/^\[|\][ \t]*(#.*)?$/, "", rest)
              m = split(rest, parts, ","); for (i = 1; i <= m; i++) add(parts[i])
              inpaths = 0
            }
            next
          }
          if (inpaths && $0 ~ /^ *- /) { item = $0; sub(/^ *- /, "", item); add(item); next }
          if (inpaths) inpaths = 0
        }
      }
      END {
        if (!haspr) exit
        if (name == "") name = fallback
        if (n == 0) printf "%s\t*\n", name
        else for (i = 1; i <= n; i++) printf "%s\t%s\n", name, globs[i]
      }
    ' "$f"
  done
}

# pr_wait_glob_match <path> <glob> — GitHub's `paths:` semantics: `**` crosses `/`, a
# single `*` and `?` do not; everything else is literal.
pr_wait_glob_match() {
  local path="$1" glob="$2" re="" c i=0
  while [[ $i -lt ${#glob} ]]; do
    c="${glob:i:1}"
    if [[ "$c" == "*" ]]; then
      if [[ "${glob:i+1:1}" == "*" ]]; then re+=".*"; i=$((i + 1)); else re+="[^/]*"; fi
    elif [[ "$c" == "?" ]]; then re+="[^/]"
    elif [[ "$c" =~ [A-Za-z0-9_/-] ]]; then re+="$c"
    else re+="\\$c"
    fi
    i=$((i + 1))
  done
  [[ "$path" =~ ^${re}$ ]]
}

# pr_wait_expected_workflows <triggers> <changed-files> — the workflow names the diff
# must trigger: one per line, sorted, unique. <triggers> is pr_wait_workflow_triggers'
# output, <changed-files> one path per line.
pr_wait_expected_workflows() {
  local triggers="$1" files="$2" name glob file
  while IFS=$'\t' read -r name glob; do
    [[ -n "$name" ]] || continue
    if [[ "$glob" == "*" ]]; then printf '%s\n' "$name"; continue; fi
    while IFS= read -r file; do
      [[ -n "$file" ]] || continue
      if pr_wait_glob_match "$file" "$glob"; then printf '%s\n' "$name"; break; fi
    done <<<"$files"
  done <<<"$triggers" | sort -u
}

# pr_wait_footer <issue-comment-bodies> <head-sha> — the latest review-verdict footer
# (`<!-- ash-swift-review-verdict: {...} -->`, posted by .github/workflows/claude-review.yml;
# docs/agents/ship-ticket.md) for <head-sha>, as one compact JSON line, or nothing. THE one
# parser of that footer: the bodies must already be filtered to github-actions[bot], and
# only `v == 1` footers naming exactly this head count. `grep` exits 1 on no match, which
# under pipefail is "no footer", not an error.
pr_wait_footer() {
  { printf '%s\n' "$1" | grep -o '<!-- ash-swift-review-verdict: {[^}]*} -->' || true; } \
    | sed -e 's/^<!-- ash-swift-review-verdict: //' -e 's/ -->$//' \
    | jq -cR --arg h "$2" 'fromjson? | select(type == "object" and .v == 1 and .sha == $h)' \
    | tail -n 1
}

# pr_wait_settled <rollup-json> <settle-seconds> <elapsed-seconds> — exit 0 when no late
# workflow can plausibly still be about to register. With any check open: never (it will
# finish, and the window starts then). With finished checks: when the newest completion is
# at least <settle> seconds old. With an empty rollup: when the command itself has been
# looking that long.
pr_wait_settled() {
  jq -e --argjson s "$2" --argjson e "$3" '
    if length == 0 then $e >= $s
    else
      ([.[] | select((.status // "COMPLETED") != "COMPLETED" or .state == "PENDING" or .state == "EXPECTED")] | length) as $open
      | ([.[] | (.completedAt // .startedAt // null) | select(. != null and . != "0001-01-01T00:00:00Z") | fromdateiso8601] | max) as $last
      | $open == 0 and $last != null and (now - $last) >= $s
    end' <<<"$1" >/dev/null 2>&1
}

# pr_wait_evaluate — the answer. Reads one JSON object on stdin:
#   {pr, pr_state, head, merge_state, rollup, expected:[workflow names], footer:{..}|null,
#    threads:int|null, settled:bool}
# and prints the result object (see bin/pr-wait's header). `threads` is null until the
# caller has the count (it is only fetched once everything else is final); a null count
# is itself a reason, so a result without it is never merge_ready.
pr_wait_evaluate() {
  jq -c --arg review "$PR_WAIT_REVIEW_WORKFLOW" '
    def ok_conclusion: . as $c | ["SUCCESS","NEUTRAL","SKIPPED"] | index($c) != null;
    def normalise:
      if .__typename == "StatusContext" then
        { workflow: null, name: .context,
          status: (if .state == "PENDING" or .state == "EXPECTED" then "pending" else "completed" end),
          conclusion: (.state | ascii_downcase),
          ok: (.state == "SUCCESS") }
      else
        { workflow: .workflowName, name: .name,
          status: (if .status == "COMPLETED" then "completed" else "pending" end),
          conclusion: ((.conclusion // "") | ascii_downcase | if . == "" then null else . end),
          ok: (.status == "COMPLETED" and ((.conclusion // "") | ok_conclusion)) }
      end;
    . as $in
    | ($in.rollup // []) as $raw
    # One entry per (workflow, check). A re-run supersedes the run it replaced, and a
    # queued re-run has no startedAt to win on, so any open entry beats a finished one;
    # otherwise the newest run.
    | ($raw | map((normalise) + {k: ((.workflowName // "") + "/" + (.name // .context // "")), t: (.startedAt // "")})
            | group_by(.k)
            | map(((map(select(.status == "pending")) | first) // max_by(.t)) | del(.k, .t))) as $checks
    | ($checks | map(select(.workflow != null) | .workflow) | unique) as $found
    | ($in.expected - $found) as $missing
    | ($checks | map(select(.status == "pending"))) as $running
    | ($checks | map(select(.status == "completed" and (.ok | not)))) as $failed
    | ($checks | map(select(.workflow == $review))) as $rv
    | ($in.footer) as $f
    | (if $f != null then (if $f.clean then "clean" else "findings" end)
       elif ($rv | length) == 0 then (if $in.settled then "not_run" else "pending" end)
       elif ($rv | any(.status == "pending")) then "pending"
       else "not_run" end) as $review
    | (if $in.pr_state == "MERGED" then "merged"
       elif $in.pr_state == "CLOSED" then "closed"
       elif $in.merge_state == "DIRTY" then "needs_rebase"
       elif ($running | length) > 0 or (($missing | length) > 0 and ($in.settled | not))
            or $review == "pending" or $in.merge_state == "UNKNOWN" then "pending"
       else "done" end) as $state
    | ($failed | map("check failed: " + (if .workflow then .workflow + " / " else "" end) + .name)) as $r_failed
    | (if $state != "done" then []
       else ($r_failed
         + ($missing | map("expected check never appeared: " + .))
         + (if $review == "not_run" then ["review: not_run (no verdict footer for this head)"]
            elif $review == "findings" then
              ["review: findings (must_fix " + ($f.must_fix|tostring) + ", should_fix "
               + ($f.should_fix|tostring) + ", nit " + ($f.nit|tostring) + ")"]
            else [] end)
         + (if $in.threads == null then ["unresolved thread count unavailable"]
            elif $in.threads > 0 then [($in.threads|tostring) + " unresolved review thread(s)"] else [] end)
         + (if $in.merge_state == "BEHIND" then ["branch is behind its base"]
            elif $in.merge_state == "DRAFT" then ["PR is a draft"]
            elif $in.merge_state == "BLOCKED" then ["blocked by branch protection (a required review or check is outstanding)"]
            else [] end))
       end) as $reasons
    | (if $state == "pending" then
         (($running | map("check: " + .name))
          + (if $in.settled then [] else ($missing | map("expected check: " + .)) end)
          + (if $review == "pending" then ["review verdict"] else [] end)
          + (if $in.merge_state == "UNKNOWN" then ["merge state"] else [] end))
       else [] end) as $waiting
    | { pr: $in.pr, head: $in.head, state: $state, merge_state: $in.merge_state,
        merge_ready: ($state == "done" and ($reasons | length) == 0),
        reasons: (if $state == "needs_rebase" then ["merge conflict with the base: rebase (Actions will not run until then)"]
                  elif $state == "merged" or $state == "closed" then ["PR is " + $state]
                  else $reasons end),
        waiting_on: $waiting,
        checks: ($checks | map({workflow, name, status, conclusion})),
        expected_workflows: $in.expected, missing_workflows: $missing,
        review: $review, review_verdict: $f, unresolved_threads: $in.threads }
  '
}
