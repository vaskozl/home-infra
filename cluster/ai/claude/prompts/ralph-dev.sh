#!/bin/bash
# Ralph loop — runs claude in a loop, building a fresh prompt each iteration
# with live repo and issue context. Sleeps between iterations
set -eu

PROMPT_FILE="${PROMPT_FILE:-/etc/claude/prompt.md}"
SLEEP_INTERVAL="${SLEEP_INTERVAL:-1800}"
TIMEOUT_INTERVAL="${TIMEOUT_INTERVAL:-120}"
# ANTHROPIC_MODEL is set by the container env (e.g. sonnet, opus, haiku).
# Claude Code resolves these aliases to the latest pinned version.

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

build_prompt() {
  repos_json=$(glab repo list -a --output json 2>/dev/null) || repos_json="[]"
  repos=$(echo "$repos_json" | jq -r '.[].path_with_namespace' 2>/dev/null)

  printf '\n## Repos\n```\n%s\n```\n' "$repos"

  local section=""
  while read -r repo; do
    issues=$(glab issue list -R "$repo" --label "agent::${HOSTNAME}" 2>&1) || true
    if echo "$issues" | grep -q '^#'; then
      section+="$(printf '### %s\n```\n%s\n```\n' "$repo" "$issues")"
    fi
  done <<< "$repos"
  if [ -n "$section" ]; then printf '\n## My in-progress issues\n%s\n' "$section"; fi

  section=""
  while read -r repo; do
    issues=$(glab issue list -R "$repo" --label 'workflow::ready for development' --label "model::${ANTHROPIC_MODEL}" 2>&1) || true
    if echo "$issues" | grep -q '^#'; then
      # Filter out issues with unresolved blocking dependencies
      filtered=""
      while IFS= read -r line; do
        if echo "$line" | grep -q '^#'; then
          iid=$(echo "$line" | sed 's/^#\([0-9]*\).*/\1/')
          if ! has_unresolved_blockers "$repo" "$iid"; then
            filtered+="${line}"$'\n'
          fi
        fi
      done <<< "$issues"
      if [ -n "$filtered" ]; then
        section+="$(printf '### %s\n```\n%s```\n' "$repo" "$filtered")"
      fi
    fi
  done <<< "$repos"
  if [ -n "$section" ]; then printf '\n## Issues ready for dev\n%s\n' "$section"; fi

  section=""
  while read -r repo; do
    mrs=$(glab mr list -R "$repo" --label agent 2>&1) || true
    # Exclude MRs that have a workflow:: label (they're already being handled)
    mrs=$(echo "$mrs" | grep -v 'workflow::' || true)
    if echo "$mrs" | grep -q '^!'; then
      section+="$(printf '### %s\n```\n%s\n```\n' "$repo" "$mrs")"
    fi
  done <<< "$repos"
  if [ -n "$section" ]; then printf '\n## MRs needing work\n%s\n' "$section"; fi
}

i=0
while true; do
  i=$((i + 1))
  echo "=== Iteration $i — $(date -Iseconds) ==="

  promptfile=$(mktemp)
  build_prompt > "$promptfile"

  # Only the "## Repos" header is always present.
  # Any additional "## " header means there's work to do.
  if ! grep -q '^## [^R]' "$promptfile"; then
    echo "--- Nothing to do, sleeping ---"
    rm -f "$promptfile"
    sleep $TIMEOUT_INTERVAL
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
    sleep $SLEEP_INTERVAL || sleep $TIMEOUT_INTERVAL
  rm -f "$tmpfile" "$promptfile"
done
