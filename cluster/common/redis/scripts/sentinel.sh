#!/bin/sh
set -e
# shellcheck source=scripts/lib.sh
. /usr/local/bin/lib.sh
[ -p /run/redis/events ] || mkfifo -m 0660 /run/redis/events
MASTER="$(resolve_master)"
cat > /run/redis/sentinel.conf <<EOF
port 26379
sentinel resolve-hostnames yes
sentinel announce-hostnames yes
sentinel announce-ip $ME
sentinel monitor mymaster $MASTER 6379 2
sentinel down-after-milliseconds mymaster 5000
sentinel failover-timeout mymaster 10000
sentinel notification-script mymaster /usr/local/bin/on-event.sh
EOF
exec redis-sentinel /run/redis/sentinel.conf
