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
# run pipeline, ignore kubeconform exit code
if ! kustomize build cluster/ $KUSTOMIZE_FLAGS | \
     yq e 'del(.sops)' - | \
     xargs kubeconform $KUBECONFORM_CONFIG
then
    true
fi
