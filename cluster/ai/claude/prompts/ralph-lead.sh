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

# Callback: issues flagged for lead review by dev agents.
_lead_wake_issues() {
  local repo="$1" issues
  issues=$(glab issue list -R "$repo" --label 'wake::lead-review' 2>&1) || true
  echo "$issues" | grep -q '^#' && printf '%s' "$issues" || true
}

# Callback: MRs with failed CI pipelines (cross-repo visibility for lead).
_lead_ci_fail_mrs() {
  local repo="$1" payload
  payload=$(fetch_open_mrs "$repo")
  format_mrs "$payload" \
    '.[] | select(.head_pipeline.status == "failed")
         | "!\(.iid)\t\(.references.full)\t\(.title)\t(main) ← (\(.source_branch))"'
}

# Callback: issues needing planning (unplanned, not excluded).
_lead_plan_issues() {
  local repo="$1" issues not_label_args=()
  for label in "${EXCLUDED_ISSUE_LABELS[@]}"; do
    not_label_args+=(--not-label "$label")
  done
  issues=$(glab issue list -R "$repo" \
    --not-label 'workflow::ready for development' \
    --not-label 'workflow::in dev' \
    --not-label 'workflow::in review' \
    --not-label 'workflow::blocked' \
    "${not_label_args[@]}" 2>&1) || true
  echo "$issues" | grep -q '^#' && printf '%s' "$issues" || true
}

build_prompt() {
  local repos
  repos=$(list_repos)

  printf '\n## Repos\n```\n%s\n```\n' "$repos"

  # Wake-up reviews from devs (highest priority)
  build_repo_section "Issues needing lead review (dev wake-up)" "$repos" _lead_wake_issues
  build_repo_section "MRs with failed CI" "$repos" _lead_ci_fail_mrs
  build_repo_section "Issues needing planning" "$repos" _lead_plan_issues
}

run_agent_loop build_prompt "$SLEEP_INTERVAL" "$TIMEOUT_INTERVAL" \
  "Planner iteration" "No unrefined issues, sleeping" "$SLEEP_INTERVAL"
