# bin/ticket-preflight-lib.sh — pure decision functions for bin/ticket-preflight:
# whether an issue's JSON says it is ready, which open PR (if any) already closes it,
# which open blockers it has. (Branch naming lives in bin/ticket-lib.sh.) The
# side-effecting calls (gh, git, mix) stay in bin/ticket-preflight; what is testable
# without them lives here, exercised by bin/ticket-preflight.test.sh — the same split
# as bin/pr-open-lib.sh / bin/after-merge-lib.sh. Requires `jq`.

# Usage: ticket_preflight_has_label <issue-json> <label>
ticket_preflight_has_label() {
  printf '%s' "$1" | jq -e --arg l "$2" '[.labels[]?.name] | index($l) != null' >/dev/null
}

# Usage: ticket_preflight_open_prs <open-prs-json> <issue>
# Prints the numbers (one per line) of open PRs that close the issue: GitHub's own
# closingIssuesReferences, or a closing keyword for it in the body (a body GitHub
# hasn't linked yet). `#12` must not match `#123`. Deliberately fails closed: prose like
# "does not close #12" also matches and refuses (open_pr); a false refusal is cheaper
# than a duplicate PR.
ticket_preflight_open_prs() {
  printf '%s' "$1" | jq -r --argjson n "$2" '
    .[]
    | select(
        ([.closingIssuesReferences[]?.number] | index($n) != null)
        or ((.body // "") | test("\\b(close[sd]?|fix(e[sd])?|resolve[sd]?)[: ]+#" + ($n | tostring) + "\\b"; "i"))
      )
    | .number'
}

# Usage: ticket_preflight_open_blockers <blocked_by-json>
# Prints "#<n>" per OPEN blocker, one per line, from the issue-dependencies list.
ticket_preflight_open_blockers() {
  printf '%s' "$1" | jq -r '.[] | select(.state == "open") | "#\(.number)"'
}
