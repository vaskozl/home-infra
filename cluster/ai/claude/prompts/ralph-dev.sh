#!/bin/bash
# Ralph loop — runs claude in a loop, building a fresh prompt each iteration
# with live repo and issue context. Sleeps between iterations
set -eu

PROMPT_FILE="${PROMPT_FILE:-/etc/claude/prompt.md}"
SLEEP_INTERVAL="${SLEEP_INTERVAL:-1800}"
TIMEOUT_INTERVAL="${TIMEOUT_INTERVAL:-120}"
# ANTHROPIC_MODEL is set by the container env (e.g. sonnet, opus, haiku).
# Claude Code resolves these aliases to the latest pinned version.

# shellcheck source=ralph-common.sh
source /usr/local/lib/ralph-common.sh

# MRs with any of these labels are excluded from "MRs needing work".
# Add labels here to suppress additional MR states from waking agents.
EXCLUDED_MR_LABELS=("workflow::in review")

build_prompt() {
  local repos
  repos=$(list_repos)

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

  # Build a jq select expression to exclude MRs with any of the excluded labels.
  # GitLab API does not support combining labels= and not[labels][]= filters.
  local jq_exclude='.'
  for label in "${EXCLUDED_MR_LABELS[@]}"; do
    jq_exclude+=" | select(.labels | map(. == $(printf '%s' "$label" | jq -Rs .)) | any | not)"
  done
  local gitlab_host="${GITLAB_HOST:-https://gitlab.sko.ai}"

  local conflict_section="" work_section=""
  while read -r repo; do
    encoded_repo=$(urlencode "$repo")
    encoded_model=$(urlencode "model::${ANTHROPIC_MODEL}")
    payload=$(curl -sf \
      "${gitlab_host}/api/v4/projects/${encoded_repo}/merge_requests?state=opened&labels=${encoded_model}&per_page=100" \
      -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" 2>/dev/null) || true

    # MRs with conflicts — wake regardless of workflow:: label
    mrs=$(printf '%s' "$payload" | jq -r \
      '.[] | select(.has_conflicts == true)
           | "!\(.iid)\t\(.references.full)\t\(.title)\t(main) ← (\(.source_branch))"' 2>/dev/null) || true
    if [ -n "$mrs" ]; then
      conflict_section+="$(printf '### %s\n```\n%s\n```\n' "$repo" "$mrs")"
    fi

    # MRs needing work (no conflict, no excluded labels)
    mrs=$(printf '%s' "$payload" | jq -r \
      ".[] | select(.has_conflicts == false or .has_conflicts == null)
           | ${jq_exclude}
           | \"!\(.iid)\t\(.references.full)\t\(.title)\t(main) ← (\(.source_branch))\"" 2>/dev/null) || true
    if [ -n "$mrs" ]; then
      work_section+="$(printf '### %s\n```\n%s\n```\n' "$repo" "$mrs")"
    fi
  done <<< "$repos"
  if [ -n "$conflict_section" ]; then printf '\n## MRs with conflicts\n%s\n' "$conflict_section"; fi
  if [ -n "$work_section" ]; then printf '\n## MRs needing work\n%s\n' "$work_section"; fi
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
