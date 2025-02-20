<img src="https://avatars.githubusercontent.com/u/61287648" align="left" width="144px" height="144px"/>

#### home-infra - Home Cloud via Flux v2 | GitOps Toolkit
> GitOps state for my cluster using flux v2

[![k8s](https://kromgo.sko.ai/k8s?format=badge)](https://k8s.io/)
[![talos](https://kromgo.sko.ai/os?format=badge)](https://talos.dev/)
[![nodes](https://kromgo.sko.ai/nodes?format=badge)](https://github.com/kashalls/kromgo)
[![pods](https://kromgo.sko.ai/pods?format=badge)](https://github.com/kashalls/kromgo)
<br />

Home infrastructure running: 3x Master Raspberry Pi 4GB + 3x Worker 8GB + 1x 11th Gen Intel Nuc:

* Apps:
  * [authelia](https://github.com/authelia/authelia) - SSO server
  * [baikal](https://sabre.io/baikal/) - {Cal,Card}Dav server
  * [blocky](https://github.com/0xERR0R/blocky) - DNS proxy and ad-blocker
  * [calibre](https://github.com/kovidgoyal/calibre) and [calibre-web](https://github.com/janeczku/calibre-web) - Lovely E-Book library management
  * [flood](https://github.com/jesec/flood) - Pretty and mobile friendly \*torrent frontend
  * [gitlab](https://gitlab.com/) - Git + Everything possibly related
  * [home-assistant](https://github.com/home-assistant/core) - Home Automation
  * [homer](https://hub.docker.com/r/b4bz/homer/tags) - Application Dashboard
  * [immich](https://immich.app/) - Self-hosted photo and video management with state-of-the-art ML
  * [jellyfin](https://github.com/jellyfin/jellyfin) - Media System
  * [maddy](https://maddy.email/) - Completel and modern mailserver
  * [my blog](https://sko.ai) - Built with via Gitlab Runners + Buildkitd
  * [ntfy](https://ntfy.sh) - Push notifications made easy
  * [omada-controller](https://github.com/mbentley/docker-omada-controller) - TP-Link Omada Network Controller
  * [thelounge](https://thelounge.chat/) - IRC client
  * [vikunja](https://github.com/go-vikunja/vikunja) - Todo-app
* System:
  * [buildkitd](https://github.com/moby/buildkit) - Super efficient container build daemon
  * [flannel](https://docs.projectcalico.org/networking/bgp) - Because flannel the lightest CNI
  * [minilb](https://github.com/vaskozl/minilb) - Ultralight DNS based load balancer
  * [cert-manager](https://github.com/jetstack/cert-manager) - Automated letsencrypt broker
  * [flux2](https://github.com/fluxcd/flux2) - Keep cluster in sync with this repo
  * [haproxytech ingress](https://github.com/haproxytech/kubernetes-ingress) - Haproxy.org Ingress controller
  * [fluentbit](https://fluentbit.io/) - Log collection and aggregation
  * [victoria-metrics](https://github.com/VictoriaMetrics/VictoriaMetrics) - Lighter prometheus alternative
  * [kube-network-policies](https://github.com/kubernetes-sigs/kube-network-policies) - Official and small netpol enforcement

## Secret management

I use [mozilla SOPS](https://github.com/mozilla/sops) for secret encryption as it [supported out of the box in Flux2](https://toolkit.fluxcd.io/guides/mozilla-sops/). After adding a passwordless secret key to your cluster, add it to your `flux-system/gotk-sync.yaml` if you want to be able do decrypt secrets in the main `flux-system` kustomization.

I use a [pre-commit hook](scripts/find-unencrypted-secrets.sh) to ensure that secrets are never pushed unencrypted. Assuming you have a `.sosp.yaml` the only thing you need to do is:

```
sops -e -i my-secret.yaml # That's it
sops my-secret.yaml # To edit it directly in your $EDITOR
```
