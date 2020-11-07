# home-infra - Home Cloud via Flux v2 | GitOps Toolkit

<img src="https://download.logo.wine/logo/Kubernetes/Kubernetes-Logo.wine.png" width="20%">

Home infrastructure running on 3x Raspberry Pi 4GB

* [authelia](https://github.com/authelia/authelia) - SSO server
* [photoprism](https://github.com/photoprism/photoprism) - Photo browser using NASNet
* [syncthing](https://github.com/syncthing/syncthing) - File synchronization
* [octoprint](https://github.com/OctoPrint/OctoPrint) - 3D printer control
* [home-assistant](https://github.com/home-assistant/core) - Home Automation
* [plex](https://github.com/plexinc/pms-docker) - Movies and show server
* [jellyfin](https://github.com/jellyfin/jellyfin) - Backup media server
* [qbittorrent](https://github.com/qbittorrent/qBittorrent) - BitTorrent client
* [pihole](https://github.com/pi-hole/pi-hole) - Local DNS Server with ad blocking
* [code-server](https://github.com/cdr/code-server) - ~~Visual Studio~~ Code Server
* [nginx-ingress](https://github.com/kubernetes/ingress-nginx) - Ingress controller
* [cert-manager](https://github.com/jetstack/cert-manager) - Automated letsencrypt broker
* [metallb](https://github.com/metallb/metallb) - Load-balancer for bare-metal
* [docker-sftp](https://github.com/emberstack/docker-sftp) - SFTP server

## Installation

### Install Rancher's k3s

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
