# bin/pr-record-lib.sh — the pure parts of bin/pr-record: validating a ship-ticket run
# record, building its hidden PR comment, and picking the right comment back out of a
# PR's comments. Side-effecting `gh` calls stay in bin/pr-record itself; this is what
# bin/pr-record.test.sh exercises directly (same split as bin/pr-threads-lib.sh).
#
# The comment format is a contract (docs/agents/ship-ticket.md, next to the review verdict
# footer); change it only with a `v` bump:
#
#     <!-- ash-swift-run-record: {"v":1,"issue":543,"pr":561,...} -->

PR_RECORD_PREFIX='<!-- ash-swift-run-record: '
PR_RECORD_SUFFIX=' -->'
# GitHub caps a comment at 65536 characters; stay well under it.
PR_RECORD_MAX_CHARS=60000

# jq predicate (input: a decoded record; needs `--argjson pr`): a version-1 record about
# exactly this PR. The ONE definition of "valid" — the writer and the reader both splice it.
PR_RECORD_VALID_JQ='type == "object" and .v == 1 and (.issue | type == "number") and .pr == $pr'

# pr_record_valid <pr> <json> — <json> satisfies PR_RECORD_VALID_JQ for <pr>.
pr_record_valid() {
  jq -e --argjson pr "$1" "$PR_RECORD_VALID_JQ" <<<"$2" >/dev/null 2>&1
}

# pr_record_line <json> — the one-line comment body. `>` is escaped to > so no string
# in the record can close the HTML comment early (`-->`); the JSON decodes identically.
pr_record_line() {
  printf '%s%s%s' "$PR_RECORD_PREFIX" "$(jq -c . <<<"$1" | sed 's/>/\\u003e/g')" "$PR_RECORD_SUFFIX"
}

# jq program: a PR's issue comments (one array) -> the comments carrying a valid v1 run
# record, in comment order: [{id, login, association, record}]. A comment counts only if
# the record is the WHOLE body, so a quoted or pasted record inside prose never does.
PR_RECORD_COMMENTS_JQ='
  [ .[]
    | (.body // "") as $b
    | select($b | startswith($pre) and endswith($suf))
    | ($b[($pre | length):(($b | length) - ($suf | length))] | fromjson?) as $r
    | select($r | '"$PR_RECORD_VALID_JQ"')
    | { id: .id, login: (.user.login // null), association: .author_association, record: $r } ]'

# pr_record_matching <comments-json> <pr> — PR_RECORD_COMMENTS_JQ applied: only records
# valid for <pr> (a record naming another PR does not count).
pr_record_matching() {
  jq -c --arg pre "$PR_RECORD_PREFIX" --arg suf "$PR_RECORD_SUFFIX" --argjson pr "$2" \
    "$PR_RECORD_COMMENTS_JQ" <<<"$1"
}

# pr_record_latest_own <matching-json> <login> — {id, record} of the last record posted by
# <login> (the one --file updates in place), or null.
pr_record_latest_own() {
  jq -c --arg me "$2" 'map(select(.login == $me)) | last // null' <<<"$1"
}

# pr_record_latest_trusted <matching-json> — {id, record} of the last record posted by
# someone with write-ish standing on the repo, or null. A reader must not trust a record
# a drive-by commenter pasted.
pr_record_latest_trusted() {
  jq -c 'map(select(.association == "OWNER" or .association == "MEMBER" or .association == "COLLABORATOR")) | last // null' <<<"$1"
}
