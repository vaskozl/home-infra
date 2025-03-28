#!/bin/bash

# Find all YAML files and process them
find . -type f \( -name "*.yaml" -o -name "*.yml" \) | while read -r file; do
  # Check if the file is a HelmRelease
  if yq eval '.kind' "$file" | grep -q "HelmRelease"; then
    # Check if spec.interval already exists
    if ! grep -E "^  interval" "$file" -q; then
      echo "Modifying: $file"
      perl -pe 's/^spec:$/spec:\n  interval: 1h/' -i $file
    fi
  fi
done
