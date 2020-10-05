#!/bin/sh
gotk bootstrap github --components=source-controller,kustomize-controller,helm-controller,notification-controller \
  --arch=arm64 --version=latest \
  --owner='vaskozl' \
  --repository='home-infra' \
  --branch='main' --personal --verbose
