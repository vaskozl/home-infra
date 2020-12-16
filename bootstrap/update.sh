#!/bin/sh
flux install \
  --components=source-controller,kustomize-controller,helm-controller,notification-controller \
  --components-extra=image-reflector-controller,image-automation-controller \
  --arch=arm64 --version=latest \
  --export  > "./cluster/flux-system/gotk-components.yaml"
