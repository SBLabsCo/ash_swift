# bin/ticket-lib.sh — the one home for how a ticket's branch and worktree are named
# (ported from SBLabsCo/SwingClips#539), shared by bin/ticket-preflight (which makes them) and
# bin/pr-open (which checks it is on one). Pure; sourced, not executable.

# Usage: ticket_slug <title>
# Lower-case `[a-z0-9-]`, runs of anything else collapsed to one dash, trimmed, capped
# at 40 chars (re-trimmed after the cap). Empty for a title with nothing sluggable.
ticket_slug() {
  local s
  s="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')"
  s="${s:0:40}"
  s="${s%-}"
  printf '%s' "$s"
}

# Usage: ticket_branch <issue> <title>   ->  ticket-<n>[-<slug>]
ticket_branch() {
  local slug
  slug="$(ticket_slug "$2")"
  if [[ -n "$slug" ]]; then printf 'ticket-%s-%s' "$1" "$slug"; else printf 'ticket-%s' "$1"; fi
}

# Usage: ticket_worktree_name <issue>   ->  ticket-<n>
# Stable per issue (no slug) so a re-run finds the same worktree even if the title was
# edited since.
ticket_worktree_name() {
  printf 'ticket-%s' "$1"
}

# Usage: ticket_branch_is_for <branch> <issue>
# True for `ticket-<issue>` and `ticket-<issue>-...`, never for another issue that merely
# shares the digits as a prefix (`ticket-5390-x` is not for 539).
ticket_branch_is_for() {
  [[ "$1" == "ticket-$2" || "$1" == "ticket-$2-"* ]]
}

# Usage: ticket_branch_is_any <branch> — any ticket's branch.
ticket_branch_is_any() {
  [[ "$1" =~ ^ticket-[0-9]+(-|$) ]]
}
