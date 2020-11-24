#!/bin/sh
flux install --components=source-controller,kustomize-controller,helm-controller,notification-controller \
  --arch=arm64 --version=latest \
  --export  > "./cluster/flux-system/gotk-components.yaml"
