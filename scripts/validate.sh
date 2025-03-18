#!/bin/sh
set -o errexit

find . -type f -name '*.yaml' -print0 | while IFS= read -r -d $'\0' file;
  do
    echo "INFO - Validating $file"
    yq e 'true' "$file" > /dev/null
done

CRD_CATALOG='https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'

kubeconform_config=("-strict" "-ignore-missing-schemas" "-schema-location" "default" "-schema-location" "$CRD_CATALOG" "-verbose")

echo "INFO - Validating cluster"
# mirror kustomize-controller build options
kustomize_flags=("--load-restrictor=LoadRestrictionsNone")

echo "INFO - Validating kustomization cluster/kustomization.yaml"
kustomize build cluster/ "${kustomize_flags[@]}" | \
  yq e "del(.sops)" - | \
  kubeconform "${kubeconform_config[@]}"
