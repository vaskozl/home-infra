#!/bin/sh
set -e
# shellcheck source=scripts/lib.sh
. /usr/local/bin/lib.sh
MASTER="$(master_addr -h "redis-sentinel.${NAMESPACE}.svc.cluster.local")"
[ -n "$MASTER" ] || MASTER="$(default_master)"
cat > /var/lib/redis/redis.conf <<EOF
port 6379
protected-mode no
dir /var/lib/redis
appendonly yes
save ""
replica-announce-ip $ME
EOF
[ "$MASTER" = "$ME" ] || echo "replicaof $MASTER 6379" >> /var/lib/redis/redis.conf
exec redis-server /var/lib/redis/redis.conf
