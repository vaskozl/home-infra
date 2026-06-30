#!/bin/sh
# Shared helpers for the redis/sentinel scripts. Sourced, not executed.
HOSTNAME="${HOSTNAME:-$(hostname)}"
ME="${HOSTNAME}.redis-headless.${NAMESPACE}.svc.cluster.local"

# Deterministic bootstrap master used before sentinel has elected one:
# pod redis-0, or ourselves when we are redis-0.
default_master() {
  [ "${HOSTNAME##*-}" = 0 ] && echo "$ME" || echo "redis-0.redis-headless.${NAMESPACE}.svc.cluster.local"
}

# Sentinel-reported master address, empty if sentinel can't be reached.
# Extra args (e.g. -h <host>) are forwarded to redis-cli.
# shellcheck disable=SC2120  # args are optional
master_addr() {
  redis-cli "$@" -p 26379 -t 2 sentinel get-master-addr-by-name mymaster 2>/dev/null | head -n1
}
