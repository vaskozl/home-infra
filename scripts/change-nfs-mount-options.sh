#!/bin/bash

# Get all PersistentVolumes (PVs) in the cluster
pvs=$(kubectl get pv -o=jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')

# Loop through each PV and change the mountOptions to nfs version 3
for pv in $pvs; do
    # Update PV with new mountOptions
    kubectl patch pv $pv --type='json' -p='[{"op": "replace", "path": "/spec/mountOptions", "value": [ "nfsvers=3", "hard", "nolock", "nocto", "noatime", "nodiratime", "retrans=5", "rsize=131072", "wsize=131072" ]}]'
done
