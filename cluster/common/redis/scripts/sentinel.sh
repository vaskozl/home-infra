#!/bin/sh
set -e
# shellcheck source=scripts/lib.sh
. /usr/local/bin/lib.sh
# Pipe the kubectl sidecar reacts to; create it early as we start before it.
[ -p /run/redis/events ] || mkfifo /run/redis/events
if [ ! -f /var/lib/redis/sentinel.conf ]; then
  MASTER="$(default_master)"
  cat > /var/lib/redis/sentinel.conf <<EOF
port 26379
sentinel resolve-hostnames yes
sentinel announce-hostnames yes
sentinel announce-ip $ME
sentinel monitor mymaster $MASTER 6379 2
sentinel down-after-milliseconds mymaster 5000
sentinel failover-timeout mymaster 10000
sentinel client-reconfig-script mymaster /usr/local/bin/push-master-label.sh
EOF
fi
# No switch event fires at boot, so seed the current master once sentinel answers.
(
  until M="$(master_addr)"; [ -n "$M" ]; do sleep 1; done
  printf '%s\n' "${M%%.*}" > /run/redis/events
) &
exec redis-sentinel /var/lib/redis/sentinel.conf
