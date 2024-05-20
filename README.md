<img src="https://avatars.githubusercontent.com/u/61287648" align="left" width="144px" height="144px"/>

#### home-infra - Home Cloud via Flux v2 | GitOps Toolkit
> GitOps state for my cluster using flux v2

[![Discord](https://img.shields.io/badge/discord-chat-7289DA.svg?maxAge=60&style=flat-square)](https://discord.gg/DNCynrJ)
[![k8s](https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Fkromgo.sko.ai%2Fquery%3Fformat%3Draw%26metric%3Dgit_version&query=%24%5B0%5D.metric.git_version&style=flat-square&label=k8s)](https://k8s.io/)
[![talos](https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Fkromgo.sko.ai%2Fquery%3Fformat%3Draw%26metric%3Dos_version&query=%24%5B0%5D.metric.osVersion&style=flat-square&label=os&color=purple)](https://talos.dev/)
[![nodes](https://img.shields.io/endpoint?url=https%3A%2F%2Fkromgo.sko.ai%2Fquery%3Fformat%3Dendpoint%26metric%3Dcluster_node_count&style=flat-square&label=nodes&color=orange)](https://github.com/kashalls/kromgo)
[![pods](https://img.shields.io/endpoint?url=https%3A%2F%2Fkromgo.sko.ai%2Fquery%3Fformat%3Dendpoint%26metric%3Dcluster_pods_running&style=flat-square&label=pods&color=yellow)](https://github.com/kashalls/kromgo)
[![GitHub last commit](https://img.shields.io/github/last-commit/vaskozl/home-infra?style=flat-square)](https://github.com/vaskozl/home-infra/commits/master)
<br />

Home infrastructure running: 3x Master Raspberry Pi 4GB + 3x Worker 8GB + 1x 11th Gen Intel Nuc:

* Apps:
  * [authelia](https://github.com/authelia/authelia) - SSO server
  * [baikal](https://sabre.io/baikal/) - {Cal,Card}Dav server
  * [blocky](https://github.com/0xERR0R/blocky) - DNS proxy and ad-blocker
  * [calibre](https://github.com/kovidgoyal/calibre) and [calibre-web](https://github.com/janeczku/calibre-web) - Lovely E-Book library management
  * [maddy](https://maddy.email/) - Completel and modern mailserver
  * [flood](https://github.com/jesec/flood) - Pretty and mobile friendly \*torrent frontend
  * [gitlab](https://gitlab.com/) - Git + Everything possibly related
  * [home-assistant](https://github.com/home-assistant/core) - Home Automation
  * [homer](https://hub.docker.com/r/b4bz/homer/tags) - Application Dashboard
  * [immich](https://immich.app/) - Self-hosted photo and video management with state-of-the-art ML
  * [inspircd](https://github.com/ngircd/ngircd) - IRC Server
  * [jellyfin](https://github.com/jellyfin/jellyfin) - Media System
  * [my blog](https://sko.ai) - Built with via Gitlab Runners + Buildkitd
  * [ntfy](https://ntfy.sh) - Push notifications made easy
  * [omada-controller](https://github.com/mbentley/docker-omada-controller) - TP-Link Omada Network Controller
  * [thelounge](https://thelounge.chat/) - IRC client
* System:
  * [buildkitd](https://github.com/moby/buildkit) - Super efficient container build daemon
  * [flannel](https://docs.projectcalico.org/networking/bgp) - Because flannel + metallb is the lightest CNI
  * [minilb](https://github.com/vaskozl/minilb) - Ultralight DNS based load balancer
  * [cert-manager](https://github.com/jetstack/cert-manager) - Automated letsencrypt broker
  * [flux2](https://github.com/fluxcd/flux2) - Keep cluster in sync with this repo
  * [haproxytech ingress](https://github.com/haproxytech/kubernetes-ingress) - Haproxy.org Ingress controller
  * [varnish](https://www.haproxy.com/blog/haproxy-varnish-and-the-single-hostname-website) - Caching reverse proxy
  * [vector](https://vector.dev) - Log collection and aggregation
  * [victoria-metrics](https://github.com/VictoriaMetrics/VictoriaMetrics) - Lighter prometheus alternative

## Secret management

I use [mozilla SOPS](https://github.com/mozilla/sops) for secret encryption as it [supported out of the box in Flux2](https://toolkit.fluxcd.io/guides/mozilla-sops/). After adding a passwordless secret key to your cluster, add it to your `flux-system/gotk-sync.yaml` if you want to be able do decrypt secrets in the main `flux-system` kustomization.

I use a [pre-commit hook](scripts/find-unencrypted-secrets.sh) to ensure that secrets are never pushed unencrypted. Assuming you have a `.sosp.yaml` the only thing you need to do is:

```
sops -e -i my-secret.yaml # That's it
sops my-secret.yaml # To edit it directly in your $EDITOR
```
