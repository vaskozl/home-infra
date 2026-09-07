#!/bin/sh
info="$(redis-cli -t 2 info replication persistence)" || exit 1
case "$info" in
  *loading:1*) exit 1 ;;
  *role:master*|*master_link_status:up*) exit 0 ;;
esac
exit 1
