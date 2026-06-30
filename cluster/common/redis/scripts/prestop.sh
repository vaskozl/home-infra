#!/bin/sh
ME="${HOSTNAME}.redis-headless.${NAMESPACE}.svc.cluster.local"
[ "$(redis-cli -p 26379 -t 2 sentinel get-master-addr-by-name mymaster 2>/dev/null | head -n1)" = "$ME" ] || exit 0
redis-cli -p 26379 sentinel failover mymaster >/dev/null 2>&1 || exit 0
i=0
while [ "$i" -lt 25 ]; do
  NEW="$(redis-cli -p 26379 -t 2 sentinel get-master-addr-by-name mymaster 2>/dev/null | head -n1)"
  [ -n "$NEW" ] && [ "$NEW" != "$ME" ] && exit 0
  sleep 1; i=$((i+1))
done
