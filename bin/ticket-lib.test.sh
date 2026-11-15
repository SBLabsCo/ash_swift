#!/usr/bin/env bash
#
# Tests for bin/ticket-lib.sh: ticket branch and worktree naming.
#
#     bin/ticket-lib.test.sh

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

# shellcheck source=./test-lib.sh
. "$HERE/test-lib.sh"
# shellcheck source=./ticket-lib.sh
. "$HERE/ticket-lib.sh"

echo "ticket_slug / ticket_branch / ticket_worktree_name"
same "bin-ticket-preflight-refuse-an-unready-t" "slug lowercases, dashes, caps at 40 and trims" \
  ticket_slug "bin/ticket-preflight — refuse an unready ticket, else create its worktree"
same "" "a title with nothing sluggable gives an empty slug" ticket_slug "—!—"
status_is 0 "  ...and that is a clean empty, not a failure" ticket_slug "—!—"
same "ticket-7-fix-it" "branch carries the issue number and slug" ticket_branch 7 "Fix it!"
same "ticket-7" "branch falls back to the bare number" ticket_branch 7 "—"
same "ticket-7" "worktree name is the bare number" ticket_worktree_name 7

echo
echo "ticket_branch_is_for / ticket_branch_is_any"
expect yes "the bare branch is for its issue" ticket_branch_is_for ticket-539 539
expect yes "a slugged branch is for its issue" ticket_branch_is_for ticket-539-bin-pr-open 539
expect no "the digit-prefix trap: ticket-5390-x is NOT for 539" ticket_branch_is_for ticket-5390-x 539
expect no "another issue's branch" ticket_branch_is_for ticket-540-x 539
expect no "main" ticket_branch_is_for main 539
expect yes "any: slugged" ticket_branch_is_any ticket-12-x
expect yes "any: bare" ticket_branch_is_any ticket-12
expect no "any: not a ticket" ticket_branch_is_any worktree-agent-1
expect no "any: no number" ticket_branch_is_any ticket-x

test_summary "ticket-lib.test.sh"
