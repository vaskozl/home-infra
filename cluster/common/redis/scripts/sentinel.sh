#!/bin/sh
set -e
ME="${HOSTNAME}.redis-headless.${NAMESPACE}.svc.cluster.local"
if [ ! -f /data/sentinel.conf ]; then
  [ "${HOSTNAME##*-}" = 0 ] && MASTER="$ME" || MASTER="redis-0.redis-headless.${NAMESPACE}.svc.cluster.local"
  cat > /data/sentinel.conf <<EOF
port 26379
sentinel resolve-hostnames yes
sentinel announce-hostnames yes
sentinel announce-ip $ME
sentinel monitor mymaster $MASTER 6379 2
sentinel down-after-milliseconds mymaster 5000
sentinel failover-timeout mymaster 10000
EOF
fi
exec redis-sentinel /data/sentinel.conf
