# bin/pr-threads-lib.sh — the pure parts of bin/pr-threads: thread-id validation and the
# jq program that shapes GitHub's GraphQL response into this tool's stable JSON.
# Side-effecting `gh` calls stay in bin/pr-threads itself; what's testable without gh
# lives here, exercised directly by bin/pr-threads.test.sh — same split as
# bin/release-check-lib.sh / bin/release-check.test.sh.

# Usage: pr_threads_valid_thread_id <value> — GraphQL node ids are URL-safe base64-ish
# (`PRRT_kwDO...`); anything else is refused before it reaches a GraphQL variable.
pr_threads_valid_thread_id() {
  [[ "$1" =~ ^[A-Za-z0-9_=-]+$ ]]
}

# jq program: slurped `gh api graphql --paginate` pages -> array of the PR's
# unresolved threads, in page order:
#   {id, path, line, outdated, author, body, url, replies: [{author, body}]}
# `author`/`body`/`url` are the thread's first (root) comment's; `line` falls back to the
# original line for a thread whose diff has since moved. A deleted ("ghost") author is
# null, not an error. Resolved threads are dropped here, not in the query, because
# GraphQL cannot filter reviewThreads by isResolved.
PR_THREADS_UNRESOLVED_JQ='
  [ .[].data.repository.pullRequest.reviewThreads.nodes[]
    | select(.isResolved | not)
    | (.comments.nodes) as $c
    | { id: .id,
        path: .path,
        outdated: .isOutdated,
        line: (.line // .originalLine),
        author: ($c[0].author.login // null),
        body: ($c[0].body // ""),
        url: ($c[0].url // null),
        replies: [ $c[1:][] | { author: (.author.login // null), body: .body } ] } ]
'

# jq program: the same slurped pages -> {"<thread id>": isResolved, ...} for every thread
# of the PR, so bin/pr-threads can tell "not this PR's thread" from "already resolved".
PR_THREADS_STATE_JQ='
  [ .[].data.repository.pullRequest.reviewThreads.nodes[] | {key: .id, value: .isResolved} ]
  | from_entries
'
