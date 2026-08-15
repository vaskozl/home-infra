#!/bin/sh
set -e

# validate each yaml file with yq
find . -type f -name '*.yaml' -print0 | while IFS= read -r -d '' file
do
    echo "INFO - Validating $file"
    yq e 'true' "$file" >/dev/null
done

CRD_CATALOG='https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'

# since sh has no arrays, just use quoted strings
KUBECONFORM_CONFIG="-strict -ignore-missing-schemas -schema-location default -schema-location $CRD_CATALOG -verbose"

echo "INFO - Validating cluster"

# same for kustomize flags
KUSTOMIZE_FLAGS="--load-restrictor=LoadRestrictionsNone"

echo "INFO - Validating kustomization cluster/kustomization.yaml"
# POSIX sh has no pipefail, so buffer the build to catch kustomize failures on
# their own line and leave kubeconform as the exit status of the final pipe
BUILD=$(mktemp)
trap 'rm -f "$BUILD"' EXIT
kustomize build cluster/ $KUSTOMIZE_FLAGS > "$BUILD"
yq e 'del(.sops)' "$BUILD" | kubeconform $KUBECONFORM_CONFIG
