#!/bin/sh
set -eu
trap 'exit 0' TERM INT
[ -p /run/redis/events ] || mkfifo -m 0660 /run/redis/events
exec 3<> /run/redis/events
apply() {
  kubectl label pod "$POD_NAME" --overwrite "isMaster=$(cat /run/redis/role 2>/dev/null || echo false)" || true
}
apply
while IFS= read -r _ <&3; do apply; done
