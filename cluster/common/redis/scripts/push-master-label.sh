#!/bin/sh
# Sentinel client-reconfig-script. On a master switch sentinel calls us with the
# old master in $4 and the new master in $6; announce both (short pod names) to
# the kubectl sidecar via the events pipe.
printf '%s %s\n' "${6%%.*}" "${4%%.*}" > /run/redis/events
