# bin/cli-lib.sh — the shared contract for the JSON-speaking bin/ CLIs
# (ported from SBLabsCo/SwingClips#545): bin/ticket-preflight, bin/pr-open, bin/pr-wait,
# bin/pr-threads, bin/pr-record and bin/after-merge. A caller (the ship-ticket workflow, an agent) learns the contract
# once. Sourced, not executable on its own; needs `jq`, and `gh` for the cli_gh* helpers.
# Requires bash >= 5 (guarded below: exit 3 on an older bash).
#
# **Exit codes — the one table, for every such CLI:**
#
#   0  ok       the script did what was asked
#   1  no       a domain "no": it understood the request and refused, or the thing asked
#               about is not so (a closed issue, an id that is not this PR's thread)
#   2  usage    the arguments are wrong; usage on stderr, NOTHING on stdout
#   3  tool     a tool or the network failed (gh, git, mix, jq missing, an unparseable
#               response): the answer is unknown, not "no"
#   4  pending  the answer is not known yet; retry later (e.g. checks still running)
#
# **Stdout is JSON, stderr is for humans.** Every non-usage failure prints one
# `{"ok":false,"reason":"<snake_case>","message":"<text>"}` object on stdout (plus any
# context the script registers in CLI_CONTEXT, e.g. {"issue":538}) and the same message
# on stderr, so a caller never has to parse an empty stdout. A CLI whose result is
# naturally per-item may instead print its own result shape on a partial failure
# (bin/pr-threads prints its per-id array with exit 3); its header says so.
#
# Usage in a script:
#
#     . "$REPO_ROOT/bin/cli-lib.sh"
#     cli_init my-script                       # names it in messages
#     cli_valid_number "$n" || cli_usage_error "'$n' is not a number"
#     cli_require_tools git gh jq              # exit 3 `missing_tool` if one is absent
#     cli_repo "$REPO_OVERRIDE"                # CLI_REPO = owner/name
#     cli_gh_json_or_fail issue --shape 'type == "object"' issue view 5 --json title
#     cli_quiet "git fetch" git fetch origin main || cli_fail "$CLI_TOOL" git_failed "git fetch failed"

# Fail fast on an old bash (macOS /bin/bash is 3.2): the bin/ scripts and their tests
# assume bash >= 5. Only BASH_VERSINFO is used, so this guard itself runs on 3.2.
if (( BASH_VERSINFO[0] < 5 )); then
  echo "bin/ scripts need bash >= 5 (found $BASH_VERSION) — brew install bash" >&2
  exit 3
fi

CLI_OK=0 CLI_NO=1 CLI_USAGE=2 CLI_TOOL=3 CLI_PENDING=4

CLI_NAME="cli"
CLI_TAG=""          # optional context shown after the name on stderr (e.g. "#538")
CLI_CONTEXT="{}"    # JSON object merged into every failure object
CLI_ERR=""          # the last cli_gh* failure's message
CLI_ERR_REASON=""   # ...and its reason: gh_failed or bad_response
CLI_REPO=""         # set by cli_repo

cli_init() { CLI_NAME="$1"; }

# Usage: cli_valid_number <value> — a positive integer, no sign, no leading zero. The
# one validator for PR and issue numbers.
cli_valid_number() {
  [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

# cli_say <message> — a human line on stderr, prefixed with the script's name.
cli_say() {
  echo "$CLI_NAME: ${CLI_TAG:+$CLI_TAG: }$*" >&2
}

# cli_usage_error <message> [<usage line>] — exit 2, nothing on stdout. The usage text is
# the given line, else the calling script's own `usage` function if it defined one.
cli_usage_error() {
  echo "$CLI_NAME: $1" >&2
  if [[ -n "${2:-}" ]]; then
    echo "$2" >&2
  elif declare -F usage >/dev/null 2>&1; then
    usage >&2
  fi
  exit "$CLI_USAGE"
}

# cli_fail <exit> <reason> <message> — the failure object on stdout, the message on
# stderr, then exit with <exit> (1 a domain no, 3 a tool failure, 4 pending; never 2 —
# usage errors print nothing on stdout, use cli_usage_error).
cli_fail() {
  local code="$1" reason="$2" msg="$3"
  cli_say "$msg"
  if command -v jq >/dev/null 2>&1; then
    jq -cn --argjson ctx "$CLI_CONTEXT" --arg r "$reason" --arg m "$msg" \
      '{ok:false} + $ctx + {reason:$r, message:$m}'
  else
    # No jq to build the object with; the one case this script cannot do it properly.
    printf '{"ok":false,"reason":"%s","message":"jq is not installed"}\n' "$reason"
  fi
  exit "$code"
}

# cli_partial_fail <reason> <message> <result_json> — exit 3 for a CLI whose steps are
# independent and which ran the rest after one failed: prints the full result object
# (a JSON object) merged over CLI_CONTEXT with `ok:false`, `reason` and `message` added,
# the message on stderr. A caller with several failures puts its own `reasons` array in
# <result_json>. The sibling of cli_fail for results that are more than an error.
cli_partial_fail() {
  cli_say "$2"
  jq -cn --argjson ctx "$CLI_CONTEXT" --argjson res "$3" --arg r "$1" --arg m "$2" \
    '$ctx + $res + {ok:false, reason:$r, message:$m}'
  exit "$CLI_TOOL"
}

# cli_require_tools <tool>... — exit 3 `missing_tool` naming the first absent one.
cli_require_tools() {
  local t
  for t in "$@"; do
    command -v "$t" >/dev/null 2>&1 || cli_fail "$CLI_TOOL" missing_tool "$t is not installed"
  done
}

# cli_gh <var> <gh args...> — run gh with its stdout captured into <var> and its stderr
# kept apart, so a warning on a successful call can never corrupt the data. No JSON check: for mutations and plain-text output. Fails
# (status 1) only when gh itself fails, with CLI_ERR = "gh <a> <b> failed: <stderr>" and
# CLI_ERR_REASON=gh_failed; <var> is only assigned on success, and CLI_ERR is cleared.
cli_gh() {
  # Underscore-prefixed, per-function-distinct locals (bash is dynamically scoped): <var> names a variable in the caller's scope, and a
  # plain `out`/`err` here would shadow a caller's own variable of that name.
  local _cli_var="$1" _cli_out _cli_err _cli_err_file _cli_rc=0; shift
  _cli_err_file="$(mktemp)"
  _cli_out="$(gh "$@" 2>"$_cli_err_file")" || _cli_rc=$?
  _cli_err="$(cat "$_cli_err_file")"
  rm -f "$_cli_err_file"
  CLI_ERR="" CLI_ERR_REASON=""
  if [[ "$_cli_rc" -ne 0 ]]; then
    CLI_ERR="gh ${1:-} ${2:-} failed${_cli_err:+: $_cli_err}"
    CLI_ERR_REASON=gh_failed
    return 1
  fi
  printf -v "$_cli_var" '%s' "$_cli_out"
}

# cli_gh_json <var> <gh args...> — cli_gh, plus: the stdout must be JSON (any JSON,
# including a bare scalar from --jq, and null). Not-JSON or empty output is status 1 with
# CLI_ERR_REASON=bad_response. Paginated GraphQL is this over gh's own
# `--paginate --slurp`. The emptiness test is jq's own (`-s` slurps, so empty input is
# length 0) — linear, unlike a bash `${out//[[:space:]]/}`, which was super-linear on bash 3.2.
cli_gh_json() {
  local _cli_var="$1" _cli_jdata; shift
  cli_gh _cli_jdata "$@" || return 1
  if ! printf '%s' "$_cli_jdata" | jq -se 'length > 0' >/dev/null 2>&1; then
    CLI_ERR="gh ${1:-} ${2:-} returned unparseable output"
    CLI_ERR_REASON=bad_response
    return 1
  fi
  printf -v "$_cli_var" '%s' "$_cli_jdata"
}

# cli_gh_json_or_fail <var> [--shape '<jq boolean>'] <gh args...> — the failing form: owns
# the mapping to `gh_failed` / `bad_response` and exit 3, so a call site is one line.
# With --shape, the parsed JSON must also satisfy the jq expression (e.g.
# 'type == "array"'), else bad_response. The soft case (a call whose failure is
# tolerated) uses cli_gh_json directly.
cli_gh_json_or_fail() {
  local _cli_var="$1" _cli_shape="" _cli_odata; shift
  if [[ "${1:-}" == "--shape" ]]; then _cli_shape="$2"; shift 2; fi
  cli_gh_json _cli_odata "$@" || cli_fail "$CLI_TOOL" "$CLI_ERR_REASON" "$CLI_ERR"
  if [[ -n "$_cli_shape" ]] && ! printf '%s' "$_cli_odata" | jq -e "$_cli_shape" >/dev/null 2>&1; then
    cli_fail "$CLI_TOOL" bad_response "gh ${1:-} ${2:-} returned an unexpected shape"
  fi
  printf -v "$_cli_var" '%s' "$_cli_odata"
}

# cli_gh_or_fail <var> <gh args...> — the failing form of cli_gh (plain-text output, no
# JSON check): a gh failure is exit 3 `gh_failed` with the message, so a call site is one
# line. <var> is only assigned on success.
cli_gh_or_fail() {
  local _cli_var="$1" _cli_fdata; shift
  cli_gh _cli_fdata "$@" || cli_fail "$CLI_TOOL" "$CLI_ERR_REASON" "$CLI_ERR"
  printf -v "$_cli_var" '%s' "$_cli_fdata"
}

# cli_repo [<override> [<dir>]] — sets CLI_REPO to "owner/name": the override when given
# (a CLI's --repo), else the repository of <dir> (default: the cwd) via `gh repo view`.
# A script that acts on its own checkout passes that checkout as <dir>, so running it
# from another repo's directory cannot resolve the wrong repository. Exit 3 (`gh_failed`,
# or `bad_response` for anything not shaped owner/name).
cli_repo() {
  local _cli_override="${1:-}" _cli_dir="${2:-}" _cli_json _cli_repo _cli_cwd="$PWD"
  if [[ -n "$_cli_override" ]]; then
    _cli_repo="$_cli_override"
  else
    [[ -z "$_cli_dir" ]] || cd "$_cli_dir" || cli_fail "$CLI_TOOL" gh_failed "cannot enter $_cli_dir"
    cli_gh_json_or_fail _cli_json --shape 'type == "object"' repo view --json owner,name
    cd "$_cli_cwd" || true
    _cli_repo="$(printf '%s' "$_cli_json" | jq -r '(.owner.login // "") + "/" + (.name // "")')"
  fi
  [[ "$_cli_repo" =~ ^[^/]+/[^/]+$ ]] \
    || cli_fail "$CLI_TOOL" bad_response "could not determine the repository (got '$_cli_repo')"
  CLI_REPO="$_cli_repo"
}

# cli_quiet <label> <cmd...> — run a noisy subprocess (git fetch, mix deps.get) with
# its output captured, so stderr carries the script's own one-line messages and not
# hundreds of progress lines. On failure the last CLI_QUIET_TAIL_LINES lines of the
# captured output are printed to stderr; the command's status is returned.
CLI_QUIET_TAIL_LINES=20
cli_quiet() {
  local label="$1" log rc=0; shift
  log="$(mktemp)"
  "$@" >"$log" 2>&1 || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    cli_say "$label failed (exit $rc); last output:"
    tail -n "$CLI_QUIET_TAIL_LINES" "$log" | sed 's/^/    /' >&2
  fi
  rm -f "$log"
  return "$rc"
}
