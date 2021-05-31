<img src="https://camo.githubusercontent.com/bd0df216af51c1525f14e62155608e448562cb4033554e001a0ac2009e545aec/68747470733a2f2f726173706265726e657465732e6769746875622e696f2f696d672f6c6f676f2e737667" align="left" width="144px" height="144px"/>

#### home-infra - Home Cloud via Flux v2 | GitOps Toolkit
> GitOps state for my cluster using flux v2

[![Discord](https://img.shields.io/badge/discord-chat-7289DA.svg?maxAge=60&style=flat-square)](https://discord.gg/DNCynrJ)
[![k8s](https://img.shields.io/badge/k8s-v1.20.2-orange?style=flat-square)](https://k8s.io/)
[![GitHub last commit](https://img.shields.io/github/last-commit/vaskozl/home-infra?style=flat-square)](https://github.com/vaskozl/home-infra/commits/master)

<br />

Home infrastructure running on Liquid cooled: 3x Master Raspberry Pi 4GB + 3x Worker 8GB running at 2.3Ghz:

* Apps:
  * [authelia](https://github.com/authelia/authelia) - SSO server
  * [radicale](https://github.com/tomsquest/docker-radicale) - {Cal,Card}Dav server
  * [gitea](https://gitea.io) - Internal git server (useful for passwords/secrets)
  * [drone](https://www.drone.io/) - CI with a native Kubernetes Runner
  * [photoprism](https://github.com/photoprism/photoprism) - Photo browser using NASNet
  * [imagestore](https://github.com/gregordr/ImageStore) - Microservices based Photo browser
  * [octoprint](https://github.com/OctoPrint/OctoPrint) - 3D printer control
  * [home-assistant](https://github.com/home-assistant/core) - Home Automation
  * [kodi-headless](https://hub.docker.com/r/linuxserver/kodi-headless) - Centralised Kodi Library indexer
  * [mojopatse](https://github.com/jhthorsen/app-mojopaste) - Pastebin written with Mojolicious
  * [rtorrent](https://github.com/jesec/rtorrent) - BitTorrent client
  * [flood](https://github.com/jesec/flood) - Pretty and mobile friendly \*torrent frontend
  * [code-server](https://github.com/cdr/code-server) - ~~Visual Studio~~ Code Server
  * [docker-sftp](https://github.com/emberstack/docker-sftp) - SFTP server
  * [omada-controller](https://github.com/mbentley/docker-omada-controller) - TP-Link Omada Network Controller
  * [docker-mailserver](https://github.com/docker-mailserver/docker-mailserver) - Postfix + Dovecot + Friends for selfhosted email
  * [filebrowser](https://github.com/filebrowser/filebrowser) - Fast web filebrowser written in Go
  * [doods](https://github.com/snowzach/doods) - Visual human and object recognition
  * [openspeedtest](https://hub.docker.com/r/openspeedtest/latest/tags?page=1&ordering=last_updated) - Speed Test testing max local and external speeds
  * [my blog](https://sko.ai) - Built with buildkitd+drone and hosted in gitea
  * [reg](https://github.com/genuinetools/reg) - Docker Registry UI
  * [wireguard](https://github.com/linuxserver/docker-wireguard) - The best VPN
  * [thelounge](https://thelounge.chat/) - IRC client
* System:
  * [flux2](https://github.com/fluxcd/flux2) - Keep cluster in sync with this repo
  * [nginx-ingress](https://github.com/kubernetes/ingress-nginx) - Ingress controller
  * [cert-manager](https://github.com/jetstack/cert-manager) - Automated letsencrypt broker
  * [calico](https://docs.projectcalico.org/networking/bgp) - My CNI of choice which supports BGP peering
  * [registry](https://hub.docker.com/_/registry) - Plain and light docker registry, runs on arm64
  * [kube-prometheus](https://github.com/prometheus-operator/kube-prometheus/tree/main/manifests) - Prometheus and friends
  * [buildkitd](https://github.com/moby/buildkit) - Super efficient container build daemon
  * [rook-ceph](https://rook.io/) - K8s storage that works properly
  * [rook-ceph-backup-tools](https://gitlab.com/jrevolt/rook-ceph-backup) - Backup with differential ceph rbd snapshots

## Installation

### Install

Installed via kubeadm on manjaro-arm lite with bootsrtap/kubeadm.yaml.

## Secret management

I use [mozilla SOPS](https://github.com/mozilla/sops) for secret encryption as it [supported out of the box in Flux2](https://toolkit.fluxcd.io/guides/mozilla-sops/). After adding a passwordless secret key to your cluster, add it to your `flux-system/gotk-sync.yaml` if you want to be able do decrypt secrets in the main `flux-system` kustomization.

I use a [pre-commit hook](scripts/find-unencrypted-secrets.sh) to ensure that secrets are never pushed unencrypted. Assuming you have a `.sosp.yaml` the only thing you need to do is:

```
sops -e -i my-secret.yaml # That's it
sops my-secret.yaml # To edit it directly in your $EDITOR
```
