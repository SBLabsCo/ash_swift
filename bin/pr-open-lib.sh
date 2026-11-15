# bin/pr-open-lib.sh — pure functions for bin/pr-open: composing a PR body from its
# parts and reading the parts back out of an existing one. The side-effecting calls (the
# push, gh pr create/edit) stay in bin/pr-open; what is testable without them lives here,
# exercised by bin/pr-open.test.sh — the same split as bin/ticket-preflight-lib.sh.
# Requires awk.

PR_OPEN_ATTRIBUTION='🤖 Generated with [Claude Code](https://claude.com/claude-code)'

# Usage: pr_open_existing_summary <body> <issue>
# Everything before the `Closes #<issue>` line, trimmed: the summary a previous
# bin/pr-open run (or a human) wrote. Empty when the body has no such line.
pr_open_existing_summary() {
  printf '%s\n' "$1" | awk -v c="Closes #$2" '
    $0 == c { found = 1; exit }
    { lines[++n] = $0 }
    END {
      if (!found) exit
      s = 1; while (s <= n && lines[s] ~ /^[[:space:]]*$/) s++
      while (n >= s && lines[n] ~ /^[[:space:]]*$/) n--
      for (i = s; i <= n; i++) print lines[i]
    }
  '
}

# Usage: pr_open_declined_section <body>
# The text under the `## Declined review findings` heading (heading excluded, trimmed),
# up to the next `## ` heading or the attribution line; empty when the body has none.
pr_open_declined_section() {
  printf '%s\n' "$1" | awk -v a="$PR_OPEN_ATTRIBUTION" '
    $0 == "## Declined review findings" { on = 1; next }
    on && (/^## / || $0 == a) { exit }
    on { lines[++n] = $0 }
    END {
      s = 1; while (s <= n && lines[s] ~ /^[[:space:]]*$/) s++
      while (n >= s && lines[n] ~ /^[[:space:]]*$/) n--
      for (i = s; i <= n; i++) print lines[i]
    }
  '
}

# Usage: pr_open_unrecognized <body> <issue>
# What a rebuild from the template would drop: lines after `Closes #<issue>` that are not
# one of the known parts (the declined section, the attribution). Empty when the body is
# entirely template-shaped, or has no Closes line.
pr_open_unrecognized() {
  printf '%s\n' "$1" | awk -v c="Closes #$2" -v a="$PR_OPEN_ATTRIBUTION" '
    $0 == c { seen = 1; next }
    !seen { next }
    $0 == "## Declined review findings" { in_declined = 1; next }
    in_declined && /^## / { in_declined = 0 }
    in_declined { next }
    /^[[:space:]]*$/ || $0 == a { next }
    { print }
  '
}

# Usage: pr_open_compose_body <summary> <issue> <declined>
# The body, in a fixed order: summary, `Closes #<issue>`, the declined findings section,
# the attribution line. An empty declined section is omitted.
pr_open_compose_body() {
  local summary="$1" issue="$2" declined="$3"
  printf '%s\n\nCloses #%s\n' "$summary" "$issue"
  if [[ -n "$declined" ]]; then
    printf '\n## Declined review findings\n\n%s\n' "$declined"
  fi
  printf '\n%s\n' "$PR_OPEN_ATTRIBUTION"
}
