#!/bin/sh
set -e
# shellcheck source=scripts/lib.sh
. /usr/local/bin/lib.sh
MASTER="$(resolve_master)"
cat > /run/redis/redis.conf <<EOF
port 6379
protected-mode no
dir /var/lib/redis
appendonly yes
save ""
replica-announce-ip $ME
EOF
[ "$MASTER" = "$ME" ] || echo "replicaof $MASTER 6379" >> /run/redis/redis.conf
exec redis-server /run/redis/redis.conf
