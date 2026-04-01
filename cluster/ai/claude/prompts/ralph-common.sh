#!/bin/bash
# Shared helpers for ralph-dev.sh and ralph-lead.sh.
# Source this file; do not execute it directly.

# List all accessible repos (newline-separated path_with_namespace).
list_repos() {
  glab repo list -a --output json 2>/dev/null \
    | jq -r '.[].path_with_namespace' 2>/dev/null \
    || true
}

# URL-encode a string using jq.
urlencode() {
  printf '%s' "$1" | jq -Rr @uri
}

# Check if an issue has unresolved (open) blocking dependencies.
# Parses "## Blocked by" sections from the issue description (CE-compatible).
# Returns 0 (has blockers) or 1 (clear to work on).
has_unresolved_blockers() {
  local repo="$1" iid="$2"
  local encoded_repo
  encoded_repo=$(echo "$repo" | sed 's|/|%2F|g')

  local description
  description=$(glab api "projects/${encoded_repo}/issues/${iid}" 2>/dev/null | jq -r '.description // ""') || return 1

  # Extract issue IIDs from "## Blocked by" section lines like "- #N" or "- #N Title"
  local blocker_iids
  blocker_iids=$(printf '%s' "$description" \
    | awk '/^## Blocked by/{found=1; next} found && /^## /{found=0} found && /^- #[0-9]+/{print}' \
    | grep -oP '#\K[0-9]+') || true

  [ -z "$blocker_iids" ] && return 1  # no blockers listed

  local open=0
  while read -r bid; do
    state=$(glab api "projects/${encoded_repo}/issues/${bid}" 2>/dev/null | jq -r '.state // "opened"') || continue
    [ "$state" != "closed" ] && open=$((open + 1))
  done <<< "$blocker_iids"

  [ "$open" -gt 0 ]
}
