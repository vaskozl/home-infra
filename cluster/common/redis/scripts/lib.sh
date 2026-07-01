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
