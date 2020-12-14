# home-infra - Home Cloud via Flux v2 | GitOps Toolkit

<img src="https://download.logo.wine/logo/Kubernetes/Kubernetes-Logo.wine.png" width="20%">

Home infrastructure running on 3x Raspberry Pi 4GB

* Apps:
  * [authelia](https://github.com/authelia/authelia) - SSO server
  * [photoprism](https://github.com/photoprism/photoprism) - Photo browser using NASNet
  * [radicale](https://github.com/tomsquest/docker-radicale) - {Cal,Card}Dav server
  * [octoprint](https://github.com/OctoPrint/OctoPrint) - 3D printer control
  * [home-assistant](https://github.com/home-assistant/core) - Home Automation
  * [jellyfin](https://github.com/jellyfin/jellyfin) - Movies and shows server
  * [qbittorrent](https://github.com/qbittorrent/qBittorrent) - BitTorrent client
  * [flood](https://github.com/jesec/flood) - Pretty and mobile friendly \*torrent frontend
  * [code-server](https://github.com/cdr/code-server) - ~~Visual Studio~~ Code Server
  * [docker-sftp](https://github.com/emberstack/docker-sftp) - SFTP server
  * [omada-controller](https://github.com/mbentley/docker-omada-controller) - TP-Link Omada Network Controller
  * [doods](https://github.com/snowzach/doods) - Visual human and object recognition
  * [openspeedtest](https://hub.docker.com/r/openspeedtest/latest/tags?page=1&ordering=last_updated) - Speed Test testing max local and external speeds
* System:
  * [flux2](https://github.com/fluxcd/flux2) - Keep cluster in sync with this repo
  * [nginx-ingress](https://github.com/kubernetes/ingress-nginx) - Ingress controller
  * [cert-manager](https://github.com/jetstack/cert-manager) - Automated letsencrypt broker
  * [metallb](https://github.com/metallb/metallb) - Load-balancer for bare-metal
  * [metrics-server](https://github.com/metallb/metallb) - Load-balancer for bare-metal

## Installation

### Install Rancher's k3s

User onedr0p has written amazing instructions which this repo is based on:

[onedr0p/k3s-gitops-arm](https://github.com/onedr0p/k3s-gitops-arm)

### Install FluxCD's GitOps toolkit

```
flux bootstrap github \
  --components=source-controller,kustomize-controller,helm-controller,notification-controller \
  --arch=arm64 \
  --version=latest \
  --owner='vaskozl' \
  --repository='home-infra' \
  --branch='main' \
  --personal \
  --verbose
```
