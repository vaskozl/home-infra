#!/bin/sh
# shellcheck source=scripts/lib.sh
. /usr/local/bin/lib.sh
[ "$(master_addr)" = "$ME" ] || exit 0
redis-cli -p 26379 sentinel failover mymaster >/dev/null 2>&1 || exit 0
i=0
while [ "$i" -lt 25 ]; do
  NEW="$(master_addr)"
  [ -n "$NEW" ] && [ "$NEW" != "$ME" ] && exit 0
  sleep 1; i=$((i+1))
done
