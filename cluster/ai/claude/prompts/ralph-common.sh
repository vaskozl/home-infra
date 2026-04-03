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
  encoded_repo=$(urlencode "$repo")

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

# Fetch open MRs for a repo via glab api. Returns raw JSON.
# Usage: fetch_open_mrs repo [extra_query_params]
# extra_query_params is appended as "&extra" (no leading &).
fetch_open_mrs() {
  local repo="$1" extra="${2:-}"
  local encoded_repo url
  encoded_repo=$(urlencode "$repo")
  url="projects/${encoded_repo}/merge_requests?state=opened&per_page=100"
  [ -n "$extra" ] && url+="&${extra}"
  glab api "$url" 2>/dev/null || true
}

# Apply a jq filter to a JSON MR payload and print matching lines.
# Usage: format_mrs payload jq_filter
format_mrs() {
  local payload="$1" jq_filter="$2"
  printf '%s' "$payload" | jq -r "$jq_filter" 2>/dev/null || true
}

# Fetch the latest pipeline for a repo and ref. Returns raw JSON.
# Usage: fetch_latest_pipeline repo ref
fetch_latest_pipeline() {
  local repo="$1" ref="$2"
  local encoded_repo encoded_ref
  encoded_repo=$(urlencode "$repo")
  encoded_ref=$(urlencode "$ref")
  glab api "projects/${encoded_repo}/pipelines?ref=${encoded_ref}&per_page=1" 2>/dev/null || true
}

# Build a formatted repo section by calling a callback for each repo.
# Prints nothing if no repo produces content.
# Usage: build_repo_section "Section Header" "$repos" callback_fn
# callback_fn(repo) should print content to stdout, or nothing if no content.
build_repo_section() {
  local header="$1" repos="$2" callback_fn="$3"
  local section=""
  while read -r repo; do
    local result
    result=$("$callback_fn" "$repo") || true
    if [ -n "$result" ]; then
      section+="$(printf '### %s\n```\n%s\n```\n' "$repo" "$result")"
    fi
  done <<< "$repos"
  if [ -n "$section" ]; then printf '\n## %s\n%s\n' "$header" "$section"; fi
}

# Run the main agent loop.
# Usage: run_agent_loop build_prompt_fn sleep_interval timeout_interval \
#          [iteration_label [idle_msg [idle_sleep]]]
#   iteration_label  prefix for the "=== N ===" banner (default: "Iteration")
#   idle_msg         message shown when nothing to do (default: "Nothing to do, sleeping")
#   idle_sleep       seconds to sleep when idle (default: timeout_interval)
run_agent_loop() {
  local build_prompt_fn="$1"
  local sleep_interval="$2"
  local timeout_interval="$3"
  local iteration_label="${4:-Iteration}"
  local idle_msg="${5:-Nothing to do, sleeping}"
  local idle_sleep="${6:-$timeout_interval}"
  local i=0 promptfile tmpfile
  while true; do
    i=$((i + 1))
    echo "=== ${iteration_label} $i — $(date -Iseconds) ==="
    promptfile=$(mktemp)
    "$build_prompt_fn" > "$promptfile"
    # Only the "## Repos" header is always present.
    # Any additional "## " header means there's work to do.
    if ! grep -q '^## [^R]' "$promptfile"; then
      echo "--- ${idle_msg} ---"
      rm -f "$promptfile"
      sleep "$idle_sleep"
      continue
    fi
    tmpfile=$(mktemp)
    claude -p "$(cat "$promptfile")" \
      --system-prompt-file "$PROMPT_FILE" \
      --verbose \
      --dangerously-skip-permissions \
      --output-format stream-json \
      --include-partial-messages \
      2>&1 | tee >(grep '<sleep/>' > "$tmpfile") || true
    grep -q '<sleep/>' "$tmpfile" && echo "--- Sleeping ---" && \
      sleep "$sleep_interval" || sleep "$timeout_interval"
    rm -f "$tmpfile" "$promptfile"
  done
}
