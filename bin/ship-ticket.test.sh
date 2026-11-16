#!/usr/bin/env bash
#
# Test for the run record .claude/workflows/ship-ticket.js persists (ported from
# SBLabsCo/SwingClips's findings retro).
#
#     bin/ship-ticket.test.sh
#
# The workflow runtime cannot import, so this suite lifts the workflow's own definitions
# (extracted, not copied) and evaluates them with node: the durable record it hands
# bin/pr-record must be one bin/pr-record accepts, or the whole record is lost. Needs `node`.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck source=./test-lib.sh
. "$HERE/test-lib.sh"
# shellcheck source=./pr-record-lib.sh
. "$HERE/pr-record-lib.sh"

JS="$ROOT/.claude/workflows/ship-ticket.js"

EXTRACT="$(awk '
  /^const newRecord =/ {on1=1}
  on1 {print}
  on1 && /^}\)/ {on1=0}
  /^const categorySlug =/ {print}
  /^const oneLine =/ {print}
  /^function durable[(]/ {on2=1}
  on2 {print}
  on2 && /^}/ {on2=0}
' "$JS")"
probe() { # <js expression using the definitions>
  node -e "$EXTRACT
process.stdout.write(String($1))"
}

echo "the durable run record (v2)"
REC="$(probe "JSON.stringify(durable(Object.assign(newRecord(7), {pr: 9, worktree: '/w',
  findings: [
    {id: 0, source: 'reviewer', severity: 'must-fix', where: 'lib/a.ex:1', problem: 'The moduledoc claims\\n  a field the IR no longer has.', fix: 'f', category: 'stale-doc-comment'},
    {id: 1, source: 'refactorer', severity: 'nit', where: 'Sources/b.swift:2', problem: 'x'.repeat(500), fix: 'f', category: 'Vacuous Test  Assertion!'},
    {id: 2, source: 'security', severity: 'nit', where: 'bin/c:3', problem: 'p', fix: 'f'}],
  fixed: [0], declined: [{id: 1, rationale: 'r', finding: 'x'}]})))")"
eq 2 "the workflow writes v2 records" "$(jq .v <<<"$REC")"
expect yes "...which bin/pr-record would accept" pr_record_writable 9 "$REC"
eq '["stale-doc-comment","vacuous-test-assertion","uncategorized"]' \
  "each finding keeps its category, slugged; a missing one is 'uncategorized'" "$(jq -c '[.findings[].category]' <<<"$REC")"
eq 'The moduledoc claims a field the IR no longer has.' "the problem is kept as one line" "$(jq -r '.findings[0].problem' <<<"$REC")"
eq 240 "...clipped" "$(jq '.findings[1].problem | length' <<<"$REC")"
eq '["fixed","declined","open"]' "each finding's outcome is still derived" "$(jq -c '[.findings[].outcome]' <<<"$REC")"
eq null "the fix text is not stored" "$(jq -c '.findings[0].fix' <<<"$REC")"
eq null "nor the worktree" "$(jq -c '.worktree' <<<"$REC")"
expect yes "the FINDINGS schema requires a category from every lens" \
  grep -q "required: \['severity', 'where', 'problem', 'fix', 'category'\]" "$JS"

test_summary "ship-ticket.test.sh"
