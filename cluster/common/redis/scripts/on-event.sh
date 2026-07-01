#!/bin/sh
set -e
# shellcheck source=scripts/lib.sh
. /usr/local/bin/lib.sh
m="$(master_addr)"
[ -n "$m" ] || exit 0
if [ "$m" = "$ME" ]; then r=true; else r=false; fi
[ "$r" = "$(cat /run/redis/role 2>/dev/null || true)" ] && exit 0
printf '%s\n' "$r" > /run/redis/role
printf 'x\n' 1<> /run/redis/events
