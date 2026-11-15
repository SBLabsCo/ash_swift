# bin/test-lib.sh — the one test harness every bin/*.test.sh suite sources
# (ported from SBLabsCo/SwingClips#545): ok/FAIL counters, `expect`/`same` helpers and a stub-PATH
# runner with one set of semantics. Sourced, not executable on its own.
#
#     . "$(dirname "${BASH_SOURCE[0]}")/test-lib.sh"
#     expect yes "a ticket branch" ticket_branch_is_for ticket-12-x 12
#     same "ticket-12" "the worktree name" ticket_worktree_name 12
#     eq 3 "three items" "$(wc -l <<<"$x")"
#     test_run "refuses a closed issue" 1 '.reason == "closed"' "not open" bin/tool 12
#     test_summary "tool.test.sh"          # last line of the suite; its status is the suite's
#
# Assertions (each counts one check, prints one line):
#   test_pass <desc> / test_fail <desc> [detail]   — record a result computed by hand
#   expect yes|no <desc> <cmd...>   — the command succeeds / fails (stdout discarded)
#   same <want> <desc> <cmd...>     — the command's stdout equals <want> (stderr dropped,
#                                     a failing command just yields what it printed)
#   status_is <want> <desc> <cmd...> — the command exits with exactly status <want>
#   eq <want> <desc> <got>          — an already-computed value equals <want>
#   test_called yes|no <desc> <substring>  — the stubs' call log ($TEST_CALLS) does / does
#                                     not contain <substring>
#   test_calls_reset                — empty the call log between scenarios
#   test_calls_count <pattern>      — prints how many logged calls match <pattern> (grep)
#   test_has_line yes|no <desc> <needle> <haystack>  — <needle> is / is not one whole
#                                     line of the multi-line <haystack>
#
# Stubs and CLI runs:
#   test_workdir                    — a fresh temp dir in $TEST_WORKDIR, removed on exit,
#                                     and an empty exported call log $TEST_CALLS
#   test_git_origin <dir>           — a real bare origin + clone with a seed commit on main;
#                                     sets TEST_ORIGIN / TEST_CLONE
#   test_git_advance_origin [<file> <content>]
#                                   — push one more commit to TEST_ORIGIN's main (empty, or
#                                     writing <content> to <file>)
#   test_stub <dir> <name>          — write stdin as an executable <dir>/<name> (mkdir -p)
#                                     that first logs "<name> <args>" to $TEST_CALLS, so a
#                                     stub's body never needs its own logging
#   test_run <desc> <exit> <stdout> <stderr-substr> <cmd...>
#                                   — run <cmd> (stdin closed), assert its exit status,
#                                     stdout and stderr; the run is left in $T_EC / $T_OUT
#                                     / $T_ERR for follow-up checks. <stdout> is "" (must
#                                     be empty), "*" (not checked) or a jq expression that
#                                     must be true on it. <stderr-substr> may be "".
#                                     Stub binaries go on PATH via the caller's
#                                     `PATH="$STUBDIR:$PATH" test_run ...`.
#
# Argument order: every assertion takes its description first (after the want-value, for
# the value-comparing ones), so a long command or jq expression can trail it, and so the
# run helper is test_run, not cli_run — its prefix keeps it out of bin/cli-lib.sh's namespace.
#
# Suites should run under `set -euo pipefail`; assertions never abort the run, they
# count, and test_summary turns the count into the exit status. Suites must not set
# their own EXIT trap (it would replace the cleanup test_workdir relies on).

# Fail fast on an old bash (macOS /bin/bash is 3.2): the bin/ scripts and their tests
# assume bash >= 5. Only BASH_VERSINFO is used, so this guard itself runs on 3.2.
if (( BASH_VERSINFO[0] < 5 )); then
  echo "bin/ scripts need bash >= 5 (found $BASH_VERSION) — brew install bash" >&2
  exit 1
fi

TEST_CHECKS=0
TEST_FAILURES=0
TEST_WORKDIR=""
TEST_CALLS=""
T_EC=0 T_OUT="" T_ERR=""

_test_cleanup() { [[ -z "$TEST_WORKDIR" ]] || rm -rf "$TEST_WORKDIR"; }
trap _test_cleanup EXIT

test_pass() {
  TEST_CHECKS=$((TEST_CHECKS + 1))
  printf '  ok   %s\n' "$1"
}

test_fail() {
  TEST_CHECKS=$((TEST_CHECKS + 1))
  TEST_FAILURES=$((TEST_FAILURES + 1))
  printf '  FAIL %s\n' "$1"
  if [[ -n "${2:-}" ]]; then printf '%s\n' "$2" | sed 's/^/         /'; fi
  return 0
}

expect() {
  local want="$1" what="$2"; shift 2
  local got=no
  "$@" >/dev/null && got=yes
  if [[ "$got" == "$want" ]]; then test_pass "$what"; else test_fail "$what" "wanted $want, got $got"; fi
}

same() {
  local want="$1" what="$2" got; shift 2
  got="$("$@" 2>/dev/null || true)"
  eq "$want" "$what" "$got"
}

status_is() {
  local want="$1" what="$2" got=0; shift 2
  "$@" >/dev/null 2>&1 || got=$?
  eq "$want" "$what" "$got"
}

eq() {
  local want="$1" what="$2" got="$3"
  if [[ "$got" == "$want" ]]; then test_pass "$what"; else
    test_fail "$what" "$(printf 'wanted %q\ngot    %q' "$want" "$got")"
  fi
}

test_called() {
  local want="$1" what="$2" needle="$3" has=no
  grep -qF -- "$needle" "$TEST_CALLS" && has=yes
  if [[ "$has" == "$want" ]]; then test_pass "$what"; else
    test_fail "$what" "$(printf 'wanted %s of %q in:\n%s' "$want" "$needle" "$(cat "$TEST_CALLS")")"
  fi
}

test_calls_count() {
  grep -c -- "$1" "$TEST_CALLS" || true
}

test_has_line() {
  local want="$1" what="$2" needle="$3" haystack="$4" has=no
  [[ $'\n'"$haystack"$'\n' == *$'\n'"$needle"$'\n'* ]] && has=yes
  if [[ "$has" == "$want" ]]; then test_pass "$what"; else
    test_fail "$what" "$(printf 'wanted %s of line %q in:\n%s' "$want" "$needle" "$haystack")"
  fi
}

test_calls_reset() {
  : > "$TEST_CALLS"
}

test_workdir() {
  TEST_WORKDIR="$(mktemp -d)"
  TEST_CALLS="$TEST_WORKDIR/calls.log"
  : > "$TEST_CALLS"
  export TEST_CALLS
}

# test_git_origin <dir> — a REAL throwaway remote for suites that must not fake git: a bare
# <dir>/origin.git and a clone of it at <dir>/clone, with one seed commit (README and
# lib/.keep) pushed to main and a committer identity configured in the clone. Sets
# TEST_ORIGIN and TEST_CLONE.
test_git_origin() {
  TEST_ORIGIN="$1/origin.git" TEST_CLONE="$1/clone"
  git init -q --bare -b main "$TEST_ORIGIN"
  git clone -q "$TEST_ORIGIN" "$TEST_CLONE" 2>/dev/null
  git -C "$TEST_CLONE" config user.email t@example.com
  git -C "$TEST_CLONE" config user.name t
  mkdir -p "$TEST_CLONE/lib"
  echo seed > "$TEST_CLONE/README"
  echo seed > "$TEST_CLONE/lib/.keep"
  git -C "$TEST_CLONE" add README lib/.keep
  git -C "$TEST_CLONE" commit -q -m seed
  git -C "$TEST_CLONE" branch -M main
  git -C "$TEST_CLONE" push -q origin main 2>/dev/null
  git -C "$TEST_CLONE" fetch -q origin
}

# test_git_advance_origin [<file> <content>] — push one more commit to $TEST_ORIGIN's main from a
# second clone: an empty commit with no arguments, else one that writes <content> to <file>.
test_git_advance_origin() {
  local other="${TEST_ORIGIN%/*}/other"
  rm -rf "$other"
  git clone -q "$TEST_ORIGIN" "$other" 2>/dev/null
  git -C "$other" config user.email t@example.com
  git -C "$other" config user.name t
  if [[ $# -ge 2 ]]; then
    mkdir -p "$(dirname "$other/$1")"
    echo "$2" > "$other/$1"
    git -C "$other" add -A
    git -C "$other" commit -q -m "advance $1"
  else
    git -C "$other" commit -q --allow-empty -m "advance"
  fi
  git -C "$other" push -q origin main 2>/dev/null
}

test_stub() {
  local dir="$1" name="$2"
  mkdir -p "$dir"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'printf '"'"'%%s %%s\\n'"'"' "%s" "$*" >> "${TEST_CALLS:-/dev/null}"\n' "$name"
    # The body's own shebang (if any) is dropped: ours is already first.
    sed '1{/^#!/d;}'
  } > "$dir/$name"
  chmod +x "$dir/$name"
}

test_run() {
  local what="$1" want_exit="$2" want_out="$3" want_err="$4"; shift 4
  local err_file problems=""
  err_file="$(mktemp)"
  T_EC=0
  T_OUT="$("$@" 2>"$err_file" </dev/null)" || T_EC=$?
  T_ERR="$(cat "$err_file")"
  rm -f "$err_file"
  [[ "$T_EC" -eq "$want_exit" ]] || problems+="exit $T_EC, wanted $want_exit; "
  case "$want_out" in
    "") [[ -z "$T_OUT" ]] || problems+="stdout not empty; " ;;
    "*") ;;
    *) printf '%s' "$T_OUT" | jq -e "$want_out" >/dev/null 2>&1 || problems+="stdout fails jq check; " ;;
  esac
  [[ -z "$want_err" || "$T_ERR" == *"$want_err"* ]] || problems+="stderr lacks '$want_err'; "
  if [[ -z "$problems" ]]; then test_pass "$what"; else
    test_fail "$what" "$(printf '%s\nstdout: %q\nstderr: %q' "$problems" "$T_OUT" "$T_ERR")"
  fi
}

test_summary() {
  echo
  if [[ "$TEST_FAILURES" -eq 0 ]]; then
    echo "$1: $TEST_CHECKS/$TEST_CHECKS ok"
  else
    echo "$1: $TEST_FAILURES/$TEST_CHECKS FAILED"
    return 1
  fi
}
