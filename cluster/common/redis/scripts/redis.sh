#!/bin/sh
set -e
ME="${HOSTNAME}.redis-headless.${NAMESPACE}.svc.cluster.local"
MASTER="$(redis-cli -h redis-sentinel.${NAMESPACE}.svc.cluster.local -p 26379 -t 2 sentinel get-master-addr-by-name mymaster 2>/dev/null | head -n1 || true)"
[ -n "$MASTER" ] || { [ "${HOSTNAME##*-}" = 0 ] && MASTER="$ME" || MASTER="redis-0.redis-headless.${NAMESPACE}.svc.cluster.local"; }
cat > /data/redis.conf <<EOF
port 6379
protected-mode no
dir /data
appendonly yes
save ""
replica-announce-ip $ME
EOF
[ "$MASTER" = "$ME" ] || echo "replicaof $MASTER 6379" >> /data/redis.conf
exec redis-server /data/redis.conf
