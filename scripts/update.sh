#!/bin/sh
flux install \
  --cluster-domain=k8s.sko.ai \
  --network-policy=false \
  --export  > "./cluster/flux-system/gotk-components.yaml"
