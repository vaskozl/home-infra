#!/bin/sh
# kubectl sidecar. Blocks on the events pipe and labels pods isMaster=true/false
# the instant a master switch (or the boot seed) is announced. SIGTERM on pod
# shutdown interrupts the read and exits us.
set -eu
[ -p /run/redis/events ] || mkfifo /run/redis/events

label() {
  kubectl label pod --field-selector="metadata.name=$1" --overwrite "isMaster=$2" || true
}

while :; do
  while read -r current previous; do
    [ -n "$current" ] && label "$current" true
    [ -n "$previous" ] && [ "$previous" != "$current" ] && label "$previous" false
  done < /run/redis/events
done
