#!/usr/bin/env bash
#
# Tests for bin/worktree-lib.sh (ported from SBLabsCo/SwingClips#545): the porcelain parsers against
# fixture text, and the main-checkout lookup against a real throwaway repository with a
# real linked worktree.
#
#     bin/worktree-lib.test.sh

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

# shellcheck source=./test-lib.sh
. "$HERE/test-lib.sh"
# shellcheck source=./worktree-lib.sh
. "$HERE/worktree-lib.sh"

porcelain="$(cat <<'EOF'
worktree /repo
HEAD deadbeef
branch refs/heads/main

worktree /repo/.claude/worktrees/agent-abc
HEAD cafebabe
branch refs/heads/feat/391-worktree-isolation

worktree /repo/.claude/worktrees/detached
HEAD f00dcafe
detached
EOF
)"

echo "worktree_registered_at"
expect yes "a registered worktree path" worktree_registered_at "$porcelain" "/repo/.claude/worktrees/agent-abc"
expect yes "a trailing slash is ignored" worktree_registered_at "$porcelain" "/repo/.claude/worktrees/agent-abc/"
expect yes "a detached worktree is still registered" worktree_registered_at "$porcelain" "/repo/.claude/worktrees/detached"
expect no "an unregistered path" worktree_registered_at "$porcelain" "/repo/.claude/worktrees/agent-zzz"
expect no "a prefix of a registered path is not a match" worktree_registered_at "$porcelain" "/repo/.claude/worktrees/agent"

echo
echo "worktree_live_branch_names"
branch_names_result="$(worktree_live_branch_names "$porcelain")"
test_has_line yes "includes the implementer worktree's checked-out branch" \
  "feat/391-worktree-isolation" "$branch_names_result"
test_has_line yes "includes the main worktree's own branch" "main" "$branch_names_result"
test_has_line no "does not include the detached sweep worktree (no branch line)" \
  "worktree" "$branch_names_result"

echo
echo "worktree_branch_at_path — the real liveness signal behind the basename heuristic above"
same "feat/391-worktree-isolation" "the branch checked out at a live worktree's path" \
  worktree_branch_at_path "$porcelain" "/repo/.claude/worktrees/agent-abc"
expect no "a path with no worktree entry" \
  worktree_branch_at_path "$porcelain" "/repo/.claude/worktrees/agent-zzz"
expect no "a path whose worktree is detached (no branch line)" \
  worktree_branch_at_path "$porcelain" "/repo/.claude/worktrees/detached"
same "feat/391-worktree-isolation" "a trailing slash on the queried path still matches (a half torn-down worktree's re-resolved path can retain one)" \
  worktree_branch_at_path "$porcelain" "/repo/.claude/worktrees/agent-abc/"

echo
echo "worktree_path_for_branch — find a ticket's worktree by branch, whatever its directory is called"
same "/repo/.claude/worktrees/agent-abc" "the path of the worktree that has the branch" \
  worktree_path_for_branch "$porcelain" "feat/391-worktree-isolation"
same "/repo" "the main checkout is a candidate like any other" worktree_path_for_branch "$porcelain" "main"
expect no "a branch no worktree has checked out" worktree_path_for_branch "$porcelain" "feat/none"
expect no "a branch name that is only a prefix of a checked-out one" worktree_path_for_branch "$porcelain" "feat/391"

echo
echo "worktree_is_protected_path — the main-checkout / self-teardown guard"
expect yes "the main checkout's own path is protected" \
  worktree_is_protected_path "/repo" "/repo" "/repo/.claude/worktrees/agent-abc"
expect yes "the checkout the script is running from is protected, even when it differs from the main checkout" \
  worktree_is_protected_path "/repo/.claude/worktrees/agent-abc" "/repo" "/repo/.claude/worktrees/agent-abc"
expect no "an unrelated worktree path is not protected" \
  worktree_is_protected_path "/repo/.claude/worktrees/agent-xyz" "/repo" "/repo/.claude/worktrees/agent-abc"

echo
echo "worktree locks — only a LIVE pid's lock is a reason to stop"
sleep 30 &
LIVE_PID=$!
DEAD_PID=2999999
lockp="$(printf 'worktree /repo/.claude/worktrees/live\nHEAD a\nbranch refs/heads/x\nlocked claude agent live (pid %s)\n\nworktree /repo/.claude/worktrees/dead\nHEAD a\nbranch refs/heads/y\nlocked claude agent dead (pid %s)\n\nworktree /repo/.claude/worktrees/nopid\nHEAD a\nbranch refs/heads/z\nlocked\n\nworktree /repo/.claude/worktrees/free\nHEAD a\nbranch refs/heads/w\n' "$LIVE_PID" "$DEAD_PID")"
same "$LIVE_PID" "the pid in a lock reason" worktree_lock_pid "$lockp" "/repo/.claude/worktrees/live"
expect no "a word merely ending in pid is not a pid marker" worktree_lock_pid \
  "$(printf 'worktree /w\nlocked rapid 5 things\n')" "/w"
expect yes "pid 1 (init) is alive though not ours to signal" worktree_live_lock_pid \
  "$(printf 'worktree /w\nlocked agent (pid 1)\n')" "/w"
expect no "a bare lock names no pid" worktree_lock_pid "$lockp" "/repo/.claude/worktrees/nopid"
expect no "an unlocked worktree has no lock pid" worktree_lock_pid "$lockp" "/repo/.claude/worktrees/free"
same "$LIVE_PID" "a live pid's lock is reported" worktree_live_lock_pid "$lockp" "/repo/.claude/worktrees/live"
expect no "a dead pid's lock is stale, not live" worktree_live_lock_pid "$lockp" "/repo/.claude/worktrees/dead"
expect no "a lock without a pid is not provably live" worktree_live_lock_pid "$lockp" "/repo/.claude/worktrees/nopid"
kill "$LIVE_PID" 2>/dev/null || true

echo
echo "main-checkout lookup, against a real repository and a real linked worktree"
test_workdir
# Resolved up front: macOS temp dirs sit behind a /var -> /private/var symlink, and the
# lib reports the resolved path.
ROOT="$(cd "$TEST_WORKDIR" && pwd -P)"
git init -q -b main "$ROOT/main"
git -C "$ROOT/main" -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m init
git -C "$ROOT/main" worktree add -q -b linked "$ROOT/main/.claude/worktrees/linked"
mkdir -p "$ROOT/main/sub" "$ROOT/plain"

same "$ROOT/main/.git" "common dir from the main checkout" worktree_common_dir "$ROOT/main"
same "$ROOT/main/.git" "common dir from a subdirectory of the main checkout" worktree_common_dir "$ROOT/main/sub"
same "$ROOT/main/.git" "common dir from a linked worktree is the main checkout's" \
  worktree_common_dir "$ROOT/main/.claude/worktrees/linked"
same "$ROOT/main" "main root from the main checkout" worktree_main_root "$ROOT/main"
same "$ROOT/main" "main root from a linked worktree" worktree_main_root "$ROOT/main/.claude/worktrees/linked"
same "$ROOT/main" "main root resolved against the given dir, not the caller's cwd" \
  bash -c "cd '$ROOT/plain' && . '$HERE/worktree-lib.sh' && worktree_main_root '$ROOT/main'"
expect no "no main root outside a checkout" worktree_main_root "$ROOT/plain"

expect no "the main checkout is not a linked worktree" worktree_is_linked "$ROOT/main"
expect no "a subdirectory of the main checkout is not a linked worktree" worktree_is_linked "$ROOT/main/sub"
expect yes "a linked worktree is linked" worktree_is_linked "$ROOT/main/.claude/worktrees/linked"
expect no "a non-checkout is not a linked worktree" worktree_is_linked "$ROOT/plain"

status_is 0 "a clean checkout is clean" worktree_is_clean "$ROOT/main/.claude/worktrees/linked"
echo scribble > "$ROOT/main/.claude/worktrees/linked/wip.txt"
status_is 1 "an untracked file makes it dirty" worktree_is_clean "$ROOT/main/.claude/worktrees/linked"
status_is 2 "a non-checkout is a git failure, not clean" worktree_is_clean "$ROOT/plain"

test_summary "worktree-lib.test.sh"
