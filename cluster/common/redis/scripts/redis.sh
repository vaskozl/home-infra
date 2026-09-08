#!/bin/sh
set -e
# shellcheck source=scripts/lib.sh
. /usr/local/bin/lib.sh
master="$(resolve_master)"
maxmemory=$(( ${MEMORY_LIMIT_BYTES:-$((384*1024*1024))} * 3 / 4 ))
cat > /run/redis/redis.conf <<EOF
port 6379
protected-mode no
dir /var/lib/redis
appendonly ${PERSISTENCE:-yes}
save ""
min-replicas-to-write 1
min-replicas-max-lag 10
replica-announce-ip $ME
maxmemory $maxmemory
maxmemory-policy ${MAXMEMORY_POLICY:-noeviction}
client-output-buffer-limit replica $(( maxmemory / 10 )) $(( maxmemory / 20 )) 60
repl-backlog-size $(( maxmemory / 100 ))
repl-diskless-load on-empty-db
EOF
[ "$master" = "$ME" ] || echo "replicaof $master 6379" >> /run/redis/redis.conf
exec redis-server /run/redis/redis.conf
