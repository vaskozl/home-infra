#!/bin/bash
# DX audit loop — analyzes agent fleet health from centralized logs.
# Runs once per boot; sleeps until KEDA scales it down.
set -eu

PROMPT_FILE="${PROMPT_FILE:-/etc/claude/prompt.md}"
SLEEP_INTERVAL="${SLEEP_INTERVAL:-7200}"
TIMEOUT_INTERVAL="${TIMEOUT_INTERVAL:-300}"

# shellcheck source=ralph-common.sh
source /usr/local/lib/ralph-common.sh

build_prompt() {
  local repos
  repos=$(list_repos)
  printf '\n## Repos\n```\n%s\n```\n' "$repos"

  # DX agent always runs on each KEDA wake — include a non-Repos header
  printf '\n## DX audit — %s\n' "$(date -Iseconds)"
  printf 'Agent logs live at /logs/ai/ on the ripgrep pod.\n'
  printf 'Each line: <JSON> pod=<pod> ctr=<ctr> ts=<ts> — strip trailing fields before piping to jq:\n\n'
  printf '```bash\n'
  printf '# Recent agent sessions (result lines carry cost, turns, outcome)\n'
  printf "kubectl exec -n logging ripgrep-0 -- rg '\"type\":\"result\"' /logs/ai/claude-worker-sonnet.log |"
  printf ' \\\n'
  printf "  tail -20 | sed 's/ pod=[^ ]* ctr=[^ ]* ts=[^ ]*//' | \\\n"
  printf "  jq '{pod: .session_id, cost: .total_cost_usd, turns: .num_turns,"
  printf " ok: (.is_error | not), preview: .result[:120]}'\n"
  printf '```\n'
}

run_agent_loop build_prompt "$SLEEP_INTERVAL" "$TIMEOUT_INTERVAL" \
  "DX audit" "No analysis needed, sleeping" "$SLEEP_INTERVAL"
