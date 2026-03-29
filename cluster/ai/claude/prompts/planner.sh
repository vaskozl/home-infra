#!/bin/bash
# Planner loop — refines and prepares issues for worker agents.
# Skips entirely if there are no unrefined issues.
set -eu

PROMPT_FILE="${PROMPT_FILE:-/etc/claude/prompt.md}"
SLEEP_INTERVAL="${SLEEP_INTERVAL:-1800}"
TIMEOUT_INTERVAL="${TIMEOUT_INTERVAL:-120}"

build_prompt() {
  repos_json=$(glab repo list -a --output json 2>/dev/null) || repos_json="[]"
  repos=$(echo "$repos_json" | jq -r '.[].path_with_namespace' 2>/dev/null)

  printf '\n## Repos\n```\n%s\n```\n' "$repos"

  local section=""
  while read -r repo; do
    issues=$(glab issue list -R "$repo" \
      --not-label 'workflow::ready for development' \
      --not-label 'workflow::in dev' \
      --not-label 'workflow::in review' \
      --not-label 'workflow::blocked' 2>&1) || true
    if echo "$issues" | grep -q '^#'; then
      section+="$(printf '### %s\n```\n%s\n```\n' "$repo" "$issues")"
    fi
  done <<< "$repos"
  if [ -n "$section" ]; then printf '\n## Issues needing planning\n%s\n' "$section"; fi
}

i=0
while true; do
  i=$((i + 1))
  echo "=== Planner iteration $i — $(date -Iseconds) ==="

  promptfile=$(mktemp)
  build_prompt > "$promptfile"

  if ! grep -q '^## [^R]' "$promptfile"; then
    echo "--- No unrefined issues, sleeping ---"
    rm -f "$promptfile"
    sleep $SLEEP_INTERVAL
    continue
  fi

  tmpfile=$(mktemp)
  claude -p "$(cat "$promptfile")" \
    --system-prompt-file "$PROMPT_FILE" \
    --model claude-opus-4-6 \
    --verbose \
    --dangerously-skip-permissions \
    --output-format stream-json \
    --include-partial-messages \
    2>&1 | tee >(grep '<sleep/>' > "$tmpfile") || true

  grep -q '<sleep/>' "$tmpfile" && echo "--- Sleeping ---" && \
    sleep $SLEEP_INTERVAL || sleep $TIMEOUT_INTERVAL
  rm -f "$tmpfile" "$promptfile"
done
