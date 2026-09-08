#!/bin/sh
# shellcheck source=scripts/lib.sh
. /usr/local/bin/lib.sh
if [ "$(master_addr)" != "$ME" ]; then
  sleep 5
  exit 0
fi

# Freeze the dataset before handing over: stop pings and pause
redis-cli config set repl-ping-replica-period 2147483647 >/dev/null 2>&1
n="$(redis-cli info replication)"; n="${n##*connected_slaves:}"; n="${n%%[!0-9]*}"
redis-cli >/dev/null 2>&1 <<CMDS
MULTI
SET prestop 1 EX 60
CLIENT PAUSE 30000 WRITE
EXEC
WAIT ${n:-0} 5000
CMDS

redis-cli -p 26379 sentinel failover mymaster >/dev/null 2>&1 || exit 0

i=0
while [ "$i" -lt 25 ]; do
  NEW="$(master_addr)"
  [ -n "$NEW" ] && [ "$NEW" != "$ME" ] && exit 0
  sleep 1; i=$((i+1))
done
exit 1
