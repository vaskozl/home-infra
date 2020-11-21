#!/bin/sh

export REPO_ROOT=$(git rev-parse --show-toplevel)


need() {
    which "$1" &>/dev/null || die "Binary '$1' is missing but required"
}

need "kubeseal"
need "kubectl"
need "sed"
need "envsubst"

. "${REPO_ROOT}/setup/.secrets.env"


envsubst < "$@" > /tmp/values.yaml
kubectl create secret generic 'cloudflare-dyndns-values' --from-file=values.yaml --dry-run -o json | kubeseal --controller-name sealed-secrets --format=yaml > cloudflare-dyndns-values.yaml
