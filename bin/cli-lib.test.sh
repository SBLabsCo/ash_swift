#!/usr/bin/env bash
#
# Tests for bin/cli-lib.sh (ported from SBLabsCo/SwingClips#545): the shared exit-code table, JSON
# failure object, number validator, gh_json capture and quiet-subprocess helpers. Each
# helper that exits is run in a throwaway `bash -c` so its `exit` is observable.
#
#     bin/cli-lib.test.sh

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

# shellcheck source=./test-lib.sh
. "$HERE/test-lib.sh"
# shellcheck source=./cli-lib.sh
. "$HERE/cli-lib.sh"

echo "cli_valid_number"
expect yes "a plain number" cli_valid_number 537
expect yes "a multi-digit number" cli_valid_number 1024
expect no "zero" cli_valid_number 0
expect no "a leading zero" cli_valid_number 012
expect no "a sign" cli_valid_number +5
expect no "a non-number" cli_valid_number abc
expect no "a number with trailing text" cli_valid_number 5x
expect no "the empty string" cli_valid_number ""

# in_cli <script body> — run it in a subshell that has the lib loaded.
in_cli() { bash -c ". '$HERE/cli-lib.sh'; cli_init demo; $1"; }

echo
echo "cli_fail / cli_usage_error"
test_run "cli_fail exits with the given code, JSON on stdout, the message on stderr" 3 \
  '.ok == false and .reason == "gh_failed" and .message == "boom"' "demo: boom" \
  in_cli 'cli_fail "$CLI_TOOL" gh_failed boom'
test_run "cli_fail merges the registered context and the tag into the failure" 1 \
  '.ok == false and .issue == 7 and .reason == "closed"' "demo: #7: not open" \
  in_cli 'CLI_TAG="#7"; CLI_CONTEXT="{\"issue\":7}"; cli_fail "$CLI_NO" closed "not open"'
test_run "a message with quotes and newlines stays valid JSON" 1 '.message == "say \"hi\"\nbye"' "" \
  in_cli 'cli_fail "$CLI_NO" odd "say \"hi\"
bye"'
test_run "cli_partial_fail exits 3 with the result, context and failure merged" 3 \
  '.ok == false and .pr == 5 and .reason == "half" and .done == [1] and .message == "one of two"' "demo: one of two" \
  in_cli 'CLI_CONTEXT="{\"pr\":5}"; cli_partial_fail half "one of two" "{\"ok\":true,\"done\":[1]}"'
test_run "cli_usage_error exits 2 with nothing on stdout and the usage on stderr" 2 "" "demo: bad flag" \
  in_cli 'cli_usage_error "bad flag" "usage: demo <n>"'
eq "usage: demo <n>" "  ...the given usage line is printed" "$(printf '%s' "$T_ERR" | sed -n 2p)"
test_run "cli_usage_error falls back to the script's own usage function" 2 "" "usage: from the function" \
  in_cli 'usage() { echo "usage: from the function"; }; cli_usage_error "bad flag"'

echo
echo "cli_require_tools"
test_run "an installed tool passes" 0 "" "" in_cli 'cli_require_tools bash sed'
test_run "a missing tool is exit 3 missing_tool, naming it" 3 \
  '.reason == "missing_tool" and (.message | contains("no-such-tool-xyz"))' "no-such-tool-xyz" \
  in_cli 'cli_require_tools bash no-such-tool-xyz'

echo
echo "cli_gh / cli_gh_json (stub gh)"
test_workdir
STUBDIR="$TEST_WORKDIR/stubs"
test_stub "$STUBDIR" gh <<'GH_STUB'
#!/usr/bin/env bash
[[ -z "${FAKE_GH_WARN:-}" ]] || echo "$FAKE_GH_WARN" >&2
[[ -z "${FAKE_GH_FAILS:-}" ]] || { echo "gh: HTTP 502" >&2; exit 1; }
if [[ -n "${FAKE_GH_FILE:-}" ]]; then cat "$FAKE_GH_FILE"; else printf '%s' "${FAKE_GH_OUT:-}"; fi
GH_STUB
gh_case() { in_cli "cli_gh_json out issue view 5 --json x; rc=\$?; echo \"rc=\$rc out=\${out:-unset} err=\$CLI_ERR reason=\$CLI_ERR_REASON\"" ; }
gh_plain() { in_cli "cli_gh out issue view 5; rc=\$?; echo \"rc=\$rc out=\${out:-unset} err=\$CLI_ERR\"" ; }
export PATH="$STUBDIR:$PATH"

eq "rc=0 out={\"a\":1} err= reason=" "a stderr warning on success neither corrupts the data nor counts as an error" \
  "$(FAKE_GH_OUT='{"a":1}' FAKE_GH_WARN="A new release of gh is available" gh_case)"
eq "rc=0 out=0 err= reason=" "a bare scalar (a --jq count) is valid JSON data" "$(FAKE_GH_OUT=0 gh_case)"
eq "rc=0 out=null err= reason=" "JSON null is data, not a failure" "$(FAKE_GH_OUT=null gh_case)"
eq "rc=1 out=unset err=gh issue view failed: gh: HTTP 502 reason=gh_failed" "a gh failure is status 1 with its stderr in CLI_ERR, data untouched" \
  "$(FAKE_GH_FAILS=1 gh_case)"
eq "rc=1 out=unset err=gh issue view returned unparseable output reason=bad_response" "non-JSON stdout is bad_response" \
  "$(FAKE_GH_OUT='oops <html>' gh_case)"
eq "rc=1 out=unset err=gh issue view returned unparseable output reason=bad_response" "empty stdout is bad_response" \
  "$(FAKE_GH_OUT='' gh_case)"
eq "rc=0 out=free text err=" "cli_gh does no JSON check (plain text and mutations)" "$(FAKE_GH_OUT='free text' gh_plain)"
eq "rc=1 out=unset err=gh issue view failed: gh: HTTP 502" "cli_gh reports a gh failure the same way" "$(FAKE_GH_FAILS=1 gh_plain)"

# A large response: a bash `${out//[[:space:]]/}` emptiness test is super-linear on macOS
# bash 3.2 (a 34 KB response hung >2 minutes); the jq-based test is linear.
BIG="$TEST_WORKDIR/big.json"
jq -n '[range(0; 3000) | {number: ., title: "a fairly long title for padding", state: "open"}]' > "$BIG"
eq "1" "  ...(the large fixture is over 100 KB)" "$([[ "$(wc -c < "$BIG")" -gt 100000 ]] && echo 1 || echo 0)"
SECONDS=0
big_out="$(FAKE_GH_FILE="$BIG" gh_case)"
eq "rc=0" "a 100 KB response parses" "${big_out%% *}"
eq "1" "  ...in well under 10 seconds" "$([[ "$SECONDS" -lt 10 ]] && echo 1 || echo 0)"

echo
echo "cli_gh_json_or_fail"
or_fail() { in_cli "cli_gh_json_or_fail out $1 issue view 5 --json x; echo \"out=\$out\""; }
test_run "valid data is assigned, no failure" 0 "*" "" env FAKE_GH_OUT='{"a":1}' bash -c "$(declare -f in_cli or_fail); HERE='$HERE' or_fail ''"
eq 'out={"a":1}' "  ...into the caller's variable" "$T_OUT"
test_run "a gh failure exits 3 gh_failed with JSON" 3 '.reason == "gh_failed"' "HTTP 502" env FAKE_GH_FAILS=1 bash -c "$(declare -f in_cli or_fail); HERE='$HERE' or_fail ''"
test_run "non-JSON exits 3 bad_response" 3 '.reason == "bad_response"' "unparseable" env FAKE_GH_OUT=oops bash -c "$(declare -f in_cli or_fail); HERE='$HERE' or_fail ''"
test_run "a shape mismatch exits 3 bad_response" 3 '.reason == "bad_response"' "unexpected shape" env FAKE_GH_OUT='{"a":1}' bash -c "$(declare -f in_cli or_fail); HERE='$HERE' or_fail \"--shape 'type == \\\"array\\\"'\""

echo
echo "cli_gh_or_fail"
plain_fail() { in_cli "cli_gh_or_fail out issue view 5; echo \"out=\$out\""; }
test_run "plain output is assigned, no JSON needed" 0 "*" "" env FAKE_GH_OUT='just text' bash -c "$(declare -f in_cli plain_fail); HERE='$HERE' plain_fail"
eq 'out=just text' "  ...into the caller's variable" "$T_OUT"
test_run "a gh failure exits 3 gh_failed with JSON" 3 '.reason == "gh_failed"' "HTTP 502" env FAKE_GH_FAILS=1 bash -c "$(declare -f in_cli plain_fail); HERE='$HERE' plain_fail"

echo
echo "cli_repo"
repo_case() { in_cli "cli_repo '$1'; echo \"repo=\$CLI_REPO\""; }
eq "repo=acme/widgets" "an override wins and gh is not asked" "$(FAKE_GH_FAILS=1 repo_case acme/widgets)"
eq "repo=SBLabsCo/ash_swift" "no override asks gh repo view" \
  "$(FAKE_GH_OUT='{"owner":{"login":"SBLabsCo"},"name":"ash_swift"}' repo_case '')"
test_run "an empty object is bad_response, not '/'" 3 '.reason == "bad_response"' "could not determine the repository" \
  env FAKE_GH_OUT='{}' bash -c "$(declare -f in_cli repo_case); HERE='$HERE' repo_case ''"
test_run "a malformed override is bad_response" 3 '.reason == "bad_response"' "could not determine" \
  bash -c "$(declare -f in_cli repo_case); HERE='$HERE' repo_case 'not-a-repo'"

echo
echo "bash >= 5 guard (both libs, under the system bash when it is older)"
OLD_BASH=/bin/bash
if [[ -x "$OLD_BASH" ]] && [[ "$("$OLD_BASH" -c 'echo ${BASH_VERSINFO[0]}')" -lt 5 ]]; then
  for lib in cli-lib test-lib; do
    code=3; [[ "$lib" == test-lib ]] && code=1
    test_run "$lib refuses to load under $("$OLD_BASH" -c 'echo $BASH_VERSION')" "$code" "" "need bash >= 5" \
      "$OLD_BASH" -c ". '$HERE/$lib.sh'; echo loaded"
  done
else
  echo "  skip /bin/bash is absent or already >= 5 (nothing older to test the guard against)"
fi

echo
echo "cli_quiet"
quiet_case() { in_cli "cli_quiet 'noisy step' bash -c '$1'; echo \"rc=\$?\""; }
test_run "a succeeding command's output is swallowed" 0 "*" "" quiet_case 'echo chatter; echo more >&2; exit 0'
eq "rc=0" "  ...and the status is returned" "$T_OUT"
eq "" "  ...nothing reached stderr" "$T_ERR"
test_run "a failing command prints a one-line failure and its output tail" 0 "*" "demo: noisy step failed (exit 7)" \
  quiet_case 'echo line-one; echo line-two >&2; exit 7'
eq "rc=7" "  ...and the command's own status is returned" "$T_OUT"
expect yes "  ...the captured output is shown after the failure line" \
  test "$(printf '%s' "$T_ERR" | grep -c 'line-two')" -eq 1
test_run "only the last CLI_QUIET_TAIL_LINES lines are shown" 0 "*" "line-30" \
  in_cli "CLI_QUIET_TAIL_LINES=3; cli_quiet step bash -c 'seq -f line-%g 1 30; exit 1' || true"
expect no "  ...earlier lines are not" test "$(printf '%s' "$T_ERR" | grep -c 'line-1$')" -eq 1

test_summary "cli-lib.test.sh"
