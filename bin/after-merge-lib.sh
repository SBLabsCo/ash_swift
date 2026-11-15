# bin/after-merge-lib.sh — the parts of bin/after-merge (ported from SBLabsCo/SwingClips#540)
# that are testable on their own: the follow-ups file contract, the PR reference line that
# makes a re-run idempotent, the duplicate test, the git-only worktree teardown and the
# main-checkout fast-forward. Sourced, not executable on its own; needs `jq` and `git`.

# The line every filed follow-up carries, and the key a re-run dedupes on. One place, so
# the writer and the matcher cannot drift.
#
# Usage: after_merge_marker <pr>
after_merge_marker() {
  printf 'Raised by the pre-PR refactor review of #%s' "$1"
}

# The follow-ups file: a JSON array of {"title": <string>, "body": <string>} — the
# review lenses' follow-up issues, as the ship-ticket workflow writes them. Extra
# keys are ignored. An empty array is valid (nothing to file).
#
# jq program: prints nothing for a valid document, else one human sentence saying what is
# wrong with it. Usage: jq -r "$AFTER_MERGE_FOLLOWUPS_PROBLEM_JQ" <file>
# shellcheck disable=SC2016  # jq source
AFTER_MERGE_FOLLOWUPS_PROBLEM_JQ='
  if type != "array" then "must be a JSON array of {title, body}"
  else
    [ to_entries[]
      | .key as $i | .value as $f
      | if ($f | type) != "object" then "item \($i) is not an object"
        elif ($f.title | type) != "string" or ($f.title | gsub("\\s"; "") | length) == 0
          then "item \($i) needs a non-empty string title"
        elif ($f.title | test("[\\r\\n]")) then "item \($i) title must be one line"
        elif ($f.body | type) != "string" then "item \($i) needs a string body"
        else empty end
    ][0] // empty
  end'

# The number of the issue in `$1` (a JSON array of issues with .number, .title and .body
# — `gh issue list --json number,title,body`) that is already this follow-up, or non-zero
# when none is: an exact title match whose body carries the PR marker (`$3`, from
# after_merge_marker). The title alone is not enough (another PR may have raised the
# same words); the marker alone is not enough (one PR raises several follow-ups).
#
# Usage: after_merge_followup_number <issues_json> <title> <marker>
after_merge_followup_number() {
  jq -er --arg t "$2" --arg m "$3" \
    '[.[] | select(.title == $t and ((.body // "") | split($m) | .[1:] | any(.[]; test("^(\\D|$)"))))][0].number // empty' <<<"$1"
}

# Report a skipped main-checkout sync: the JSON on stdout, the reason on stderr.
_am_skip() {
  jq -cn --arg r "$1" '{action: "skipped", reason: $r}'
  cli_say "main checkout not fast-forwarded: $1"
}

# Fast-forward the main checkout at `$1` to `$2`/main (default origin) when that cannot disturb
# anyone (ported from SBLabsCo/SwingClips#595): only when it is on `main`, its working tree is clean
# (staged, unstaged and untracked; gitignored files do not count), and the move is a pure
# fast-forward. Otherwise it changes nothing and says why — a dirty or switched checkout is
# someone's work in progress. Never merges, never resets, and touches only the checkout it is
# given (a linked worktree is a different checkout).
#
# Prints one JSON object: {"action":"fast_forwarded","from":sha,"to":sha}, {"action":"already_current"}
# or {"action":"skipped","reason":text}. Always returns 0: a skip is a report, never an error.
# Human narration goes to stderr. Needs cli-lib.sh (cli_quiet, cli_say) and `jq`.
#
# Usage: after_merge_sync_main <main_root> [<remote>]
after_merge_sync_main() {
  local main="$1" remote="${2:-origin}" branch clean old new
  branch="$(git -C "$main" symbolic-ref --short -q HEAD 2>/dev/null)" || branch=""
  if [[ "$branch" != main ]]; then
    _am_skip "main checkout is on ${branch:+branch $branch}${branch:-a detached HEAD}, not main"; return 0
  fi
  clean=0; worktree_is_clean "$main" || clean=$?
  if [[ "$clean" -eq 2 ]]; then _am_skip "git status failed in the main checkout"; return 0; fi
  if [[ "$clean" -ne 0 ]]; then _am_skip "main checkout has local changes"; return 0; fi
  cli_quiet "git fetch $remote main" git -C "$main" fetch "$remote" main || { _am_skip "git fetch $remote main failed"; return 0; }
  old="$(git -C "$main" rev-parse HEAD 2>/dev/null)" && new="$(git -C "$main" rev-parse "$remote/main" 2>/dev/null)" \
    || { _am_skip "cannot resolve HEAD or $remote/main"; return 0; }
  if [[ "$old" == "$new" ]]; then
    jq -cn '{action: "already_current"}'; return 0
  fi
  if ! git -C "$main" merge-base --is-ancestor "$old" "$new" 2>/dev/null; then
    _am_skip "main checkout has commits that are not on $remote/main, so the move is not a fast-forward"; return 0
  fi
  if ! cli_quiet "git merge --ff-only" git -C "$main" merge --ff-only "$new"; then
    _am_skip "git merge --ff-only failed"; return 0
  fi
  cli_say "main checkout fast-forwarded ${old:0:12} -> ${new:0:12}"
  jq -cn --arg f "$old" --arg t "$new" '{action: "fast_forwarded", from: $f, to: $t}'
}

# Remove one linked worktree and its branches — git only, nothing else is per-worktree in
# this repo. The caller has already refused the unsafe cases (the main checkout, its own
# checkout, a live session's lock, uncommitted changes, unmerged commits); this does:
#   1. `git worktree unlock` (a stale lock) and `git worktree remove --force`, then prune;
#   2. `git branch -D <branch>` — the PR's merged head branch — never `main`;
#   3. the harness's `worktree-<dir name>` placeholder branch (Claude Code checks it out
#      when it creates a worktree; the implementer branches away from it), deleted only when
#      no worktree has it checked out and it is an ancestor of `main` or `origin/main` —
#      one carrying commits of its own is left alone and named on stderr.
# Idempotent: what is already gone is skipped. Narration on stderr (cli_say). Returns 1
# when the worktree or the branch is still there afterwards.
#
# Usage: after_merge_teardown <main_root> <abs_path> <branch>
after_merge_teardown() {
  local main="$1" path="${2%/}" branch="$3" placeholder listing
  placeholder="worktree-$(basename "$path")"
  git -C "$main" worktree unlock "$path" >/dev/null 2>&1 || true
  listing="$(git -C "$main" worktree list --porcelain 2>/dev/null)" || return 1
  if worktree_registered_at "$listing" "$path" || [[ -d "$path" ]]; then
    cli_quiet "git worktree remove" git -C "$main" worktree remove --force "$path" || return 1
    cli_say "removed worktree $path"
  fi
  git -C "$main" worktree prune >/dev/null 2>&1 || true
  if [[ -n "$branch" && "$branch" != main ]] && git -C "$main" show-ref --verify --quiet "refs/heads/$branch"; then
    cli_quiet "git branch -D $branch" git -C "$main" branch -D "$branch" || return 1
    cli_say "deleted branch $branch"
  fi
  if [[ "$placeholder" != "$branch" ]] && git -C "$main" show-ref --verify --quiet "refs/heads/$placeholder"; then
    listing="$(git -C "$main" worktree list --porcelain 2>/dev/null)" || listing=""
    if worktree_live_branch_names "$listing" | grep -qxF "$placeholder"; then
      cli_say "placeholder branch $placeholder is checked out in another worktree; left alone"
    elif git -C "$main" merge-base --is-ancestor "$placeholder" main 2>/dev/null \
        || git -C "$main" merge-base --is-ancestor "$placeholder" origin/main 2>/dev/null; then
      git -C "$main" branch -D "$placeholder" >/dev/null 2>&1 && cli_say "deleted placeholder branch $placeholder"
    else
      cli_say "placeholder branch $placeholder has commits beyond main; left alone"
    fi
  fi
  return 0
}
