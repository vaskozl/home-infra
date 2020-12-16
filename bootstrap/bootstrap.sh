#!/bin/sh
flux bootstrap github \
  --components=source-controller,kustomize-controller,helm-controller,notification-controller \
  --components-extra=image-reflector-controller,image-automation-controller \
  --arch=arm64 --version=latest \
  --owner='vaskozl' \
  --repository='home-infra' \
  --path='./cluster'
  --branch='main' --personal --verbose
