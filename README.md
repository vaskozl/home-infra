# home-infra - Home Cloud via GitOps Toolkit

<img src="https://download.logo.wine/logo/Kubernetes/Kubernetes-Logo.wine.png" width="40%">

Home infrastructure running on 3x Raspberry Pi 4GB

## Installation

### Install Rancher's k3

User onedr0p has written amazing instructions which this repo is based on:

[onedr0p/k3s-gitops-arm](https://github.com/onedr0p/k3s-gitops-arm)

### Install FluxCD's GitOps toolkit

```
gotk bootstrap github \
  --components=source-controller,kustomize-controller,helm-controller,notification-controller \
  --arch=arm64 \
  --version=latest \
  --owner='vaskozl' \
  --repository='home-infra' \
  --branch='main' \
  --personal \
  --verbose
```
<img src="https://i.imgur.com/A5RkwYB.jpghttps://i.imgur.com/A5RkwYB.jpg" width="40%">
