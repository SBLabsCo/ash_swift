#!/usr/bin/env bash
#
# Tests for bin/orchestration-fresh (ported from SBLabsCo/SwingClips#595), against REAL git: a throwaway
# bare origin and a clone holding a copy of the script (so it resolves ITS main checkout
# there, never the real one). No network.
#
#     bin/orchestration-fresh.test.sh

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=./test-lib.sh
. "$HERE/test-lib.sh"

test_workdir
ROOT="$(cd "$TEST_WORKDIR" && pwd -P)"
test_git_origin "$ROOT"
MAIN="$TEST_CLONE"
mkdir -p "$MAIN/bin" "$MAIN/.claude/workflows" "$MAIN/.claude/agents" "$MAIN/.claude/skills/x"
cp "$HERE/orchestration-fresh" "$HERE/cli-lib.sh" "$HERE/worktree-lib.sh" "$MAIN/bin/"
echo v1 > "$MAIN/.claude/workflows/ship-ticket.js"
echo v1 > "$MAIN/.claude/agents/implementer.md"
echo v1 > "$MAIN/.claude/skills/x/SKILL.md"
git -C "$MAIN" add -A
git -C "$MAIN" commit -q -m "orchestration"
git -C "$MAIN" push -q origin main 2>/dev/null
OF="$MAIN/bin/orchestration-fresh"

echo "usage"
test_run "an unknown argument is a usage error" 2 "" "unknown argument" "$OF" --frob
test_run "--remote needs a name" 2 "" "--remote needs a name" "$OF" --remote
test_run "--help prints the header" 0 "*" "" "$OF" --help

echo "fresh"
test_run "an up-to-date checkout is fresh" 0 '.ok and .behind == 0 and .paths == []' "" "$OF"

echo "behind, but not on the orchestration"
test_git_advance_origin README "docs only"
test_run "commits that touch none of the watched paths are still fresh" 0 '.ok and .behind == 1 and .paths == []' "" "$OF"

echo "stale"
test_git_advance_origin .claude/workflows/ship-ticket.js v2
test_run "a changed workflow is stale, naming the path, the distance and the fix" 1 \
  '.ok == false and .reason == "stale" and .behind == 2 and .paths == [".claude/workflows/ship-ticket.js"] and (.message | contains("merge --ff-only origin/main") and contains(".claude/workflows/ship-ticket.js"))' \
  "behind origin/main" "$OF"
test_git_advance_origin .claude/skills/y/SKILL.md new
test_run "every differing path is named, a new file included" 1 \
  '.paths == [".claude/skills/y/SKILL.md", ".claude/workflows/ship-ticket.js"]' "" "$OF"

echo "caught up"
git -C "$MAIN" merge -q --ff-only origin/main
test_run "after the fast-forward it is fresh again" 0 '.ok and .behind == 0 and .paths == []' "" "$OF"

echo "local edits"
echo local > "$MAIN/.claude/agents/implementer.md"
test_run "a locally edited agent definition differs from origin/main, and a fast-forward is not offered" 1 \
  '.reason == "stale" and .paths == [".claude/agents/implementer.md"] and (.message | contains("push or revert") and (contains("merge --ff-only") | not))' "" "$OF"
git -C "$MAIN" checkout -q -- .claude/agents/implementer.md

echo "ahead"
echo local > "$MAIN/.claude/agents/implementer.md"
git -C "$MAIN" commit -q -am "local, unpushed"
test_run "a checkout ahead of origin/main is told to push or revert, not to fast-forward" 1 \
  '.reason == "stale" and .ahead == 1 and .behind == 0 and (.message | contains("push or revert") and (contains("merge --ff-only") | not))' "" "$OF"
git -C "$MAIN" reset -q --hard origin/main

echo "unknown"
test_run "a fetch that fails is a tool failure, not a verdict" 3 '.ok == false and .reason == "git_failed"' "git fetch" "$OF" --remote nowhere

test_summary "orchestration-fresh.test.sh"
