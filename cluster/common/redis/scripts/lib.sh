#!/bin/sh
HOSTNAME="${HOSTNAME:-$(hostname)}"
ME="${HOSTNAME}.redis-headless.${NAMESPACE}.svc.cluster.local"

default_master() {
  [ "${HOSTNAME##*-}" = 0 ] && echo "$ME" || echo "redis-0.redis-headless.${NAMESPACE}.svc.cluster.local"
}

# shellcheck disable=SC2120  # args optional
master_addr() {
  redis-cli "$@" -p 26379 -t 2 sentinel get-master-addr-by-name mymaster 2>/dev/null | head -n1
}

# Ask the running sentinels (peers) for the current master; only fall back to
# the bootstrap default (redis-0) when none answer, i.e. a cold start with no
# quorum. Avoids a restarted redis-0 wrongly assuming it is master.
resolve_master() {
  m="$(master_addr -h "redis-sentinel.${NAMESPACE}.svc.cluster.local")"
  [ -n "$m" ] && echo "$m" || default_master
}
