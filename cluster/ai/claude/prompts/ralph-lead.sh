#!/bin/bash
# Planner loop — refines and prepares issues for worker agents.
# Skips entirely if there are no unrefined issues.
set -eu

PROMPT_FILE="${PROMPT_FILE:-/etc/claude/prompt.md}"
SLEEP_INTERVAL="${SLEEP_INTERVAL:-300}"
TIMEOUT_INTERVAL="${TIMEOUT_INTERVAL:-60}"

# shellcheck source=ralph-common.sh
source /usr/local/lib/ralph-common.sh

# Issues with these labels are never shown to the planner.
# Add labels here to exclude additional issue types (e.g. renovate, spam).
EXCLUDED_ISSUE_LABELS=(renovate)

build_prompt() {
  local repos
  repos=$(list_repos)

  printf '\n## Repos\n```\n%s\n```\n' "$repos"

  # Wake-up reviews from devs (highest priority)
  local section=""
  while read -r repo; do
    wake_issues=$(glab issue list -R "$repo" --label 'wake::lead-review' 2>&1) || true
    if echo "$wake_issues" | grep -q '^#'; then
      section+="$(printf '### %s\n```\n%s\n```\n' "$repo" "$wake_issues")"
    fi
  done <<< "$repos"
  if [ -n "$section" ]; then printf '\n## Issues needing lead review (dev wake-up)\n%s\n' "$section"; fi

  # MRs with failed CI pipelines (cross-repo visibility for lead)
  local gitlab_host="${GITLAB_HOST:-https://gitlab.sko.ai}"
  local ci_section=""
  while read -r repo; do
    encoded_repo=$(urlencode "$repo")
    payload=$(curl -sf \
      "${gitlab_host}/api/v4/projects/${encoded_repo}/merge_requests?state=opened&per_page=100" \
      -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" 2>/dev/null) || true
    mrs=$(printf '%s' "$payload" | jq -r \
      '.[] | select(.head_pipeline.status == "failed")
           | "!\(.iid)\t\(.references.full)\t\(.title)\t(main) ← (\(.source_branch))"' 2>/dev/null) || true
    if [ -n "$mrs" ]; then
      ci_section+="$(printf '### %s\n```\n%s\n```\n' "$repo" "$mrs")"
    fi
  done <<< "$repos"
  if [ -n "$ci_section" ]; then printf '\n## MRs with failed CI\n%s\n' "$ci_section"; fi

  # Build --not-label flags for glab
  local not_label_args=()
  for label in "${EXCLUDED_ISSUE_LABELS[@]}"; do
    not_label_args+=(--not-label "$label")
  done

  # Issues needing planning
  section=""
  while read -r repo; do
    issues=$(glab issue list -R "$repo" \
      --not-label 'workflow::ready for development' \
      --not-label 'workflow::in dev' \
      --not-label 'workflow::in review' \
      --not-label 'workflow::blocked' \
      "${not_label_args[@]}" 2>&1) || true
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
    --verbose \
    --dangerously-skip-permissions \
    --output-format stream-json \
    --include-partial-messages \
    2>&1 | tee >(grep '<sleep/>' > "$tmpfile") || true

  grep -q '<sleep/>' "$tmpfile" && echo "--- Sleeping ---" && \
    sleep $SLEEP_INTERVAL || sleep $TIMEOUT_INTERVAL
  rm -f "$tmpfile" "$promptfile"
done
