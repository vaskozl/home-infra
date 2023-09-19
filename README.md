<img src="https://avatars.githubusercontent.com/u/61287648" align="left" width="144px" height="144px"/>

#### home-infra - Home Cloud via Flux v2 | GitOps Toolkit
> GitOps state for my cluster using flux v2

[![Discord](https://img.shields.io/badge/discord-chat-7289DA.svg?maxAge=60&style=flat-square)](https://discord.gg/DNCynrJ)
[![k8s](https://img.shields.io/badge/k8s-v1.28.0-orange?style=flat-square)](https://k8s.io/)
[![talos](https://img.shields.io/badge/talos-v1.5.1-yellow?style=flat-square)](https://k8s.io/)
[![GitHub last commit](https://img.shields.io/github/last-commit/vaskozl/home-infra?style=flat-square)](https://github.com/vaskozl/home-infra/commits/master)

<br />

Home infrastructure running on Liquid cooled: 3x Master Raspberry Pi 4GB + 3x Worker 8GB + 1x 11th Gen Intel Nuc:

* Apps:
  * [authelia](https://github.com/authelia/authelia) - SSO server
  * [radicale](https://github.com/tomsquest/docker-radicale) - {Cal,Card}Dav server
  * [gitea](https://gitea.io) - Internal git server (useful for passwords/secrets)
  * [gitlab](https://gitlab.com/) - Git + Everything possibly related
  * [home-assistant](https://github.com/home-assistant/core) - Home Automation
  * [docker-mailserver](https://github.com/docker-mailserver/docker-mailserver) - Postfix + Dovecot + Friends for selfhosted email
  * [calibre](https://github.com/kovidgoyal/calibre) and [calibre-web](https://github.com/janeczku/calibre-web) - Lovely E-Book library management
  * [flood](https://github.com/jesec/flood) - Pretty and mobile friendly \*torrent frontend
  * [omada-controller](https://github.com/mbentley/docker-omada-controller) - TP-Link Omada Network Controller
  * [doods](https://github.com/snowzach/doods) - Visual human and object recognition
  * [openspeedtest](https://hub.docker.com/r/openspeedtest/latest/tags?page=1&ordering=last_updated) - Speed Test testing max local and external speeds
  * [my blog](https://sko.ai) - Built with via Gitlab Runners + Buildkitd
  * [thelounge](https://thelounge.chat/) - IRC client
  * [ngircd](https://github.com/ngircd/ngircd) - IRC Server
  * [znc](https://github.com/znc/znc) - IRC bouncer
  * [homer](https://hub.docker.com/r/b4bz/homer/tags) - Application Dashboard
* System:
  * [flux2](https://github.com/fluxcd/flux2) - Keep cluster in sync with this repo
  * [ingress-nginx](https://github.com/kubernetes/ingress-nginx) - Ingress controller
  * [cert-manager](https://github.com/jetstack/cert-manager) - Automated letsencrypt broker
  * [calico](https://docs.projectcalico.org/networking/bgp) - My CNI of choice which supports BGP peering
  * [victoria-metrics](https://github.com/VictoriaMetrics/VictoriaMetrics) - Lighter prometheus alternative
  * [buildkitd](https://github.com/moby/buildkit) - Super efficient container build daemon

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
