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
# Returns 0 (has blockers) or 1 (clear to work on).
has_unresolved_blockers() {
  local repo="$1" iid="$2"
  local encoded_repo
  encoded_repo=$(echo "$repo" | sed 's|/|%2F|g')

  local project_id
  project_id=$(glab api "projects/${encoded_repo}" 2>/dev/null | jq -r '.id') || return 1

  local open_blockers
  open_blockers=$(glab api "projects/${project_id}/issues/${iid}/links" 2>/dev/null \
    | jq '[.[] | select(.link_type == "is_blocked_by" and .state != "closed")] | length') || return 1

  [ "$open_blockers" -gt 0 ]
}
