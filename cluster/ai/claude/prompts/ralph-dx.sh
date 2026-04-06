#!/bin/bash
# DX audit loop — analyzes agent fleet health from centralized logs.
# Runs once per boot; sleeps until KEDA scales it down.
set -eu

PROMPT_FILE="${PROMPT_FILE:-/etc/claude/prompt.md}"
SLEEP_INTERVAL="${SLEEP_INTERVAL:-7200}"
TIMEOUT_INTERVAL="${TIMEOUT_INTERVAL:-300}"

# shellcheck source=ralph-common.sh
source /usr/local/lib/ralph-common.sh

_exec_rg() {
  kubectl exec -n logging ripgrep-0 -- rg "$@" /logs 2>/dev/null || true
}

build_prompt() {
  local repos
  repos=$(list_repos)
  printf '\n## Repos\n```\n%s\n```\n' "$repos"

  printf '\n## Agent log analysis\n'
  printf 'Use `kubectl exec -n logging ripgrep-0 -- rg <pattern> /logs` to search logs.\n'
  printf 'Logs use format: {msg} pod={pod} ctr={ctr} ts={ts}\n\n'

  # Sample recent errors across all claude pods
  printf '### Recent errors (claude pods)\n```\n'
  _exec_rg -i 'error' --glob '*claude*' -c | tail -20
  printf '\n```\n'

  printf '### Panics, crashes, OOM\n```\n'
  _exec_rg -i 'panic|crash|fatal|killed|OOM' --glob '*claude*' -c | tail -20
  printf '\n```\n'

  printf '### Rate limits and API errors\n```\n'
  _exec_rg -i 'rate.limit|429|overloaded|capacity' --glob '*claude*' -c | tail -20
  printf '\n```\n'
}

run_agent_loop build_prompt "$SLEEP_INTERVAL" "$TIMEOUT_INTERVAL" \
  "DX audit" "No analysis needed, sleeping" "$SLEEP_INTERVAL"
