#!/bin/sh
flux install \
  --network-policy=false \
  --export  > "./cluster/flux-system/gotk-components.yaml"
