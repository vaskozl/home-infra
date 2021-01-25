<img src="https://camo.githubusercontent.com/bd0df216af51c1525f14e62155608e448562cb4033554e001a0ac2009e545aec/68747470733a2f2f726173706265726e657465732e6769746875622e696f2f696d672f6c6f676f2e737667" align="left" width="144px" height="144px"/>

#### home-infra - Home Cloud via Flux v2 | GitOps Toolkit
> GitOps state for my cluster using flux v2

[![Discord](https://img.shields.io/badge/discord-chat-7289DA.svg?maxAge=60&style=flat-square)](https://discord.gg/DNCynrJ)
[![k8s](https://img.shields.io/badge/k8s-v1.20.2-orange?style=flat-square)](https://k8s.io/)
[![GitHub last commit](https://img.shields.io/github/last-commit/vaskozl/home-infra?style=flat-square)](https://github.com/vaskozl/home-infra/commits/master)

<br />

Home infrastructure running on 3x Raspberry Pi 4GB

* Apps:
  * [authelia](https://github.com/authelia/authelia) - SSO server
  * [photoprism](https://github.com/photoprism/photoprism) - Photo browser using NASNet
  * [radicale](https://github.com/tomsquest/docker-radicale) - {Cal,Card}Dav server
  * [gitea](https://gitea.io) - Internal git server (useful for passwords/secrets)
  * [drone](https://www.drone.io/) - CI with a native Kubernetes Runner
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
  * [my blog](https://va.sko.ai) - Built with buildkitd+drone and hosted in gitea
* System:
  * [flux2](https://github.com/fluxcd/flux2) - Keep cluster in sync with this repo
  * [nginx-ingress](https://github.com/kubernetes/ingress-nginx) - Ingress controller
  * [cert-manager](https://github.com/jetstack/cert-manager) - Automated letsencrypt broker
  * [metallb](https://github.com/metallb/metallb) - Load-balancer for bare-metal
  * [metrics-server](https://github.com/metallb/metallb) - Load-balancer for bare-metal
  * [redis](https://hub.docker.com/_/redis) - KV store for authelia
  * [cockroachdb](https://hub.docker.com/r/cockroachdb/cockroach) - Postgress like DB for gitea/authelia
  * [registry](https://hub.docker.com/_/registry) - Plain and light docker registry, runs on arm64
  * [buildkitd](https://github.com/moby/buildkit) - Super efficient container build daemon


## Installation

### Install

Installed via kubeadm on manjaro-arm lite with bootsrtap/kubeadm.yaml.

## Secret management

I [mozilla SOPS](https://github.com/mozilla/sops) for secret encryption as it [supported out of the box in Flux2](https://toolkit.fluxcd.io/guides/mozilla-sops/).

I use a [pre-commit hook](scripts/find-unencrypted-secrets.sh) to ensure that secrets are never pushed unencrypted. Assuming you have a `.sosp.yaml` the only thing you need to do is:

```
sops -e -i my-secret.yaml # That's it
sops my-secret.yaml # To edit it directly in you $EDITOR
```
