#!/bin/sh
# Ralph loop — runs qwen in a loop, building a fresh prompt each iteration
# with live repo and issue context. Sleeps between iterations; the agent can
# request a longer sleep by outputting <sleep>SECONDS</sleep>.
set -eu

PROMPT_FILE="${PROMPT_FILE:-/etc/qwen/prompt.md}"
SLEEP_DEFAULT="${SLEEP_DEFAULT:-300}"

build_prompt() {
  sed "s/HOSTNAME/$(hostname)/g" "$PROMPT_FILE"

  repos_json=$(glab repo list -a --output json 2>/dev/null) || repos_json="[]"

  printf '\n## Repos\n```\n'
  echo "$repos_json" | jq -r '.[].path_with_namespace' 2>/dev/null
  printf '```\n'

  printf '\n## Open issues\n'
  echo "$repos_json" | jq -r '.[].path_with_namespace' 2>/dev/null \
    | while read -r repo; do
        issues=$(glab issue list -R "$repo" 2>&1) || true
        if echo "$issues" | grep -q '^#'; then
          printf '```$ glab issue list -R %s\n%s\n```\n' "$repo" "$issues"
        fi
      done
}

i=0
while true; do
  i=$((i + 1))
  echo "=== Iteration $i — $(date -Iseconds) ==="

  prompt=$(build_prompt)
  result=$(qwen --yolo -p "$prompt" 2>&1) || true
  echo "$result"

  sleep_dur=$SLEEP_DEFAULT
  custom=$(echo "$result" | sed -n 's/.*<sleep>\([0-9]*\)<\/sleep>.*/\1/p' | tail -1)
  [ -n "$custom" ] && sleep_dur=$custom

  echo "--- Sleeping ${sleep_dur}s ---"
  sleep "$sleep_dur"
done
