#!/bin/bash
# Ralph loop — runs claude in a loop, building a fresh prompt each iteration
# with live repo and issue context. Sleeps between iterations
set -eu

PROMPT_FILE="${PROMPT_FILE:-/etc/claude/prompt.md}"
SLEEP_INTERVAL="${SLEEP_INTERVAL:-300}"
TIMEOUT_INTERVAL="${TIMEOUT_INTERVAL:-60}"
# ANTHROPIC_MODEL is set by the container env (e.g. sonnet, opus).
# Claude Code resolves these aliases to the latest pinned version.

# shellcheck source=ralph-common.sh
source /usr/local/lib/ralph-common.sh

# MRs with any of these labels are excluded from "MRs needing work".
# Add labels here to suppress additional MR states from waking agents.
EXCLUDED_MR_LABELS=("workflow::in review")

# Callback: open issues assigned to this agent.
_dev_my_issues() {
  local repo="$1" issues
  issues=$(glab issue list -R "$repo" --label "agent::${HOSTNAME}" 2>&1) || true
  echo "$issues" | grep -q '^#' && printf '%s' "$issues" || true
}

# Callback: issues ready for dev, filtered for unresolved blockers.
_dev_ready_issues() {
  local repo="$1" issues filtered="" line iid
  issues=$(glab issue list -R "$repo" \
    --label 'workflow::ready for development' \
    --label "model::${ANTHROPIC_MODEL}" 2>&1) || true
  echo "$issues" | grep -q '^#' || return 0
  while IFS= read -r line; do
    if echo "$line" | grep -q '^#'; then
      iid=$(echo "$line" | sed 's/^#\([0-9]*\).*/\1/')
      is_claimed "$repo" "$iid" && continue
      has_unresolved_blockers "$repo" "$iid" || filtered+="${line}"$'\n'
    fi
  done <<< "$issues"
  printf '%s' "$filtered"
}

build_prompt() {
  local repos
  repos=$(list_repos)

  printf '\n## Repos\n```\n%s\n```\n' "$repos"

  build_repo_section "My in-progress issues" "$repos" _dev_my_issues
  build_repo_section "Issues ready for dev" "$repos" _dev_ready_issues

  # MR sections: one API call per repo, three filter passes on the same payload.
  # GitLab API does not support combining labels= and not[labels][]= filters,
  # so the exclude filter is applied client-side via jq.
  local encoded_model jq_exclude ci_fail_section="" conflict_section="" work_section=""
  encoded_model=$(urlencode "model::${ANTHROPIC_MODEL}")
  jq_exclude='.'
  for label in "${EXCLUDED_MR_LABELS[@]}"; do
    jq_exclude+=" | select(.labels | map(. == $(printf '%s' "$label" | jq -Rs .)) | any | not)"
  done

  while read -r repo; do
    local payload mrs
    payload=$(fetch_open_mrs "$repo" "labels=${encoded_model}")

    # MRs with failed CI pipelines — highest priority, wake immediately
    mrs=$(format_mrs "$payload" \
      '.[] | select(.head_pipeline.status == "failed")
           | "!\(.iid)\t\(.references.full)\t\(.title)\t(main) ← (\(.source_branch))"')
    [ -n "$mrs" ] && ci_fail_section+="$(printf '### %s\n```\n%s\n```\n' "$repo" "$mrs")"

    # MRs with conflicts — wake regardless of workflow:: label
    mrs=$(format_mrs "$payload" \
      '.[] | select(.has_conflicts == true)
           | "!\(.iid)\t\(.references.full)\t\(.title)\t(main) ← (\(.source_branch))"')
    [ -n "$mrs" ] && conflict_section+="$(printf '### %s\n```\n%s\n```\n' "$repo" "$mrs")"

    # MRs needing work (no conflict, no excluded labels)
    mrs=$(format_mrs "$payload" \
      ".[] | select(.has_conflicts == false or .has_conflicts == null)
           | ${jq_exclude}
           | \"!\(.iid)\t\(.references.full)\t\(.title)\t(main) ← (\(.source_branch))\"")
    [ -n "$mrs" ] && work_section+="$(printf '### %s\n```\n%s\n```\n' "$repo" "$mrs")"
  done <<< "$repos"

  if [ -n "$ci_fail_section" ]; then printf '\n## MRs with failed CI\n%s\n' "$ci_fail_section"; fi
  if [ -n "$conflict_section" ]; then printf '\n## MRs with conflicts\n%s\n' "$conflict_section"; fi
  if [ -n "$work_section" ]; then printf '\n## MRs needing work\n%s\n' "$work_section"; fi
}

run_agent_loop build_prompt "$SLEEP_INTERVAL" "$TIMEOUT_INTERVAL"
