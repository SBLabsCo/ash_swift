# bin/worktree-lib.sh — neutral git-worktree helpers shared by bin/ticket-preflight,
# bin/pr-open and bin/after-merge (ported from SBLabsCo/SwingClips#545): finding the main
# checkout, and reading `git worktree list --porcelain`. Sourced, not executable on its own.
#
# Everything here is read-only; nothing creates, switches or removes anything.

# Usage: worktree_common_dir [<dir>]
# The absolute, symlink-resolved git common dir of the checkout containing <dir>
# (default: the cwd) — the main checkout's `.git`, from the main checkout and from any
# linked worktree alike. Fails when <dir> is not in a git checkout. `--git-common-dir`
# prints a path relative to <dir> for the main checkout, so it is resolved against
# <dir>, never against whatever directory the caller happens to be in.
worktree_common_dir() {
  local dir="${1:-.}" common
  common="$(git -C "$dir" rev-parse --git-common-dir 2>/dev/null)" || return 1
  [[ "$common" == /* ]] || common="$dir/$common"
  (cd "$common" 2>/dev/null && pwd -P)
}

# Usage: worktree_main_root [<dir>] — the main checkout's absolute path (the parent of
# the common dir, which holds `.git`), resolved from <dir>'s own repository. Scripts
# pass their own location here, never the caller's cwd, so running one from some other
# repo cannot act on that repo.
worktree_main_root() {
  local common
  common="$(worktree_common_dir "${1:-.}")" || return 1
  dirname "$common"
}

# Usage: worktree_is_linked [<dir>] — true when <dir>'s checkout is a linked worktree
# (its git dir differs from the common dir), false for the main checkout, a non-checkout,
# or when git is missing. Compares resolved absolute paths: `--git-dir` is a relative
# ".git" in the main checkout, so a raw string compare would depend on the cwd.
worktree_is_linked() {
  local dir="${1:-.}" git_dir common
  git_dir="$(git -C "$dir" rev-parse --git-dir 2>/dev/null)" || return 1
  [[ "$git_dir" == /* ]] || git_dir="$dir/$git_dir"
  git_dir="$(cd "$git_dir" 2>/dev/null && pwd -P)" || return 1
  common="$(worktree_common_dir "$dir")" || return 1
  [[ "$git_dir" != "$common" ]]
}

# Usage: worktree_registered_at <porcelain_output> <abs_path>
# True when `git worktree list --porcelain` output (`$1`) has a worktree entry at
# `$2` (a trailing slash is ignored). Says nothing about whether the directory exists.
worktree_registered_at() {
  printf '%s\n' "$1" | grep -qxF "worktree ${2%/}"
}

# The branch (short name) checked out by the worktree at `$2` (an absolute path) per
# `git worktree list --porcelain` output (`$1`), or a non-zero exit if no worktree
# sits there or it's detached. `$2` is normalized with a trailing-slash strip — a path
# resolved for a directory that is already gone can retain a trailing slash a live
# `cd && pwd -P` never would, and would then fail to match the exact `worktree ` line.
#
# Usage: worktree_branch_at_path <porcelain_output> <abs_path>
worktree_branch_at_path() {
  local porcelain="$1" target="${2%/}" line cur_path=""
  while IFS= read -r line; do
    case "$line" in
      "worktree "*) cur_path="${line#worktree }" ;;
      "branch "*)
        if [[ "$cur_path" == "$target" ]]; then
          printf '%s' "${line#branch refs/heads/}"
          return 0
        fi
        ;;
    esac
  done <<<"$porcelain"
  return 1
}

# The branch names (short form) currently checked out by *any* worktree — main
# included — per `git worktree list --porcelain` output (`$1`). The real "is this branch
# checked out anywhere" signal: unlike `worktree_live_basenames`'s directory-basename
# heuristic, a branch checked out in a worktree whose directory was renamed or moved
# still shows up, because it comes straight off the porcelain's own
# `branch refs/heads/<name>` line. A detached-HEAD worktree contributes no line.
#
# Usage: worktree_live_branch_names <porcelain_output>
worktree_live_branch_names() {
  local porcelain="$1" line
  while IFS= read -r line; do
    case "$line" in
      "branch refs/heads/"*) printf '%s\n' "${line#branch refs/heads/}" ;;
    esac
  done <<<"$porcelain"
}

# Whether `$1` (a resolved absolute path) is the main checkout (`$2`) or the checkout
# the calling script is itself running from (`$3`, its REPO_ROOT) — either one a
# teardown (bin/after-merge) must refuse. The two are usually the same path, but not always: a script also
# works when run from *inside* a linked worktree, and pointing it at itself is a
# distinct, equally-real way to hand it the wrong target.
#
# Usage: worktree_is_protected_path <abs_path> <main_path> <repo_root>
worktree_is_protected_path() {
  local abs="$1" main="$2" repo_root="$3"
  [[ "$abs" == "$main" || "$abs" == "$repo_root" ]]
}

# Whether the checkout at `$1` has uncommitted changes (tracked or untracked). Status:
# 0 clean, 1 dirty, 2 git failed — callers must not read a failure as "clean".
#
# Usage: worktree_is_clean <dir>
worktree_is_clean() {
  local out
  out="$(git -C "$1" status --porcelain 2>/dev/null)" || return 2
  [[ -z "$out" ]]
}

# The pid named by the lock on the worktree at `$2` per the porcelain (`$1`): the
# harness locks a session's worktree with a reason like "claude agent ... (pid 1234)".
# Prints the first number after "pid" in the lock reason; non-zero when the worktree is
# not locked or its lock names no pid.
#
# Usage: worktree_lock_pid <porcelain_output> <abs_path>
worktree_lock_pid() {
  local porcelain="$1" target="${2%/}" line cur_path=""
  while IFS= read -r line; do
    case "$line" in
      "worktree "*) cur_path="${line#worktree }" ;;
      "locked"*)
        if [[ "$cur_path" == "$target" && "$line" =~ (^|[^[:alnum:]])pid[[:space:]=:]*([0-9]+) ]]; then
          printf '%s' "${BASH_REMATCH[2]}"
          return 0
        fi
        ;;
    esac
  done <<<"$porcelain"
  return 1
}

# The pid of a LIVE process holding the lock on the worktree at `$2` (`kill -0`), or
# non-zero: not locked, a lock with no pid we can read, or a dead pid's stale lock. Only
# the live case is a reason to refuse a teardown; the rest are safe to proceed past.
#
# Usage: worktree_live_lock_pid <porcelain_output> <abs_path>
worktree_live_lock_pid() {
  local pid err
  pid="$(worktree_lock_pid "$1" "$2")" || return 1
  # EPERM ("Operation not permitted") means the process exists but is another user's:
  # alive, so still a reason to stop.
  err="$(kill -0 "$pid" 2>&1)" || [[ "$err" == *"not permitted"* ]] || return 1
  printf '%s' "$pid"
}

# The absolute path of the worktree that has branch `$2` (short name) checked out, per
# the porcelain output (`$1`), or a non-zero exit if none does. The inverse of
# `worktree_branch_at_path`: a ticket's worktree is found by its branch, never by
# directory name (harness `agent-*` dirs and `ticket-<n>` dirs both exist). The main
# checkout is a candidate like any other; callers compare against `worktree_main_root`.
#
# Usage: worktree_path_for_branch <porcelain_output> <branch>
worktree_path_for_branch() {
  local porcelain="$1" want="$2" line cur_path=""
  while IFS= read -r line; do
    case "$line" in
      "worktree "*) cur_path="${line#worktree }" ;;
      "branch refs/heads/"*)
        if [[ "${line#branch refs/heads/}" == "$want" ]]; then
          printf '%s' "$cur_path"
          return 0
        fi
        ;;
    esac
  done <<<"$porcelain"
  return 1
}
