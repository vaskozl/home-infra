#!/bin/bash

# Check for the numeric argument
if [ $# -eq 0 ]; then
    echo "Error: Please enter a replica count as the first argument."
    exit 1
fi

replica_count="$1"

# Function to scale Deployments
scale_deployments() {
    echo '' > deployments.bak
    kubectl get deployment --all-namespaces -o custom-columns="NAMESPACE:.metadata.namespace,DEPLOYMENT:.metadata.name,VOLUMES:.spec.template.spec.volumes[?(@.persistentVolumeClaim.claimName)].name" --no-headers | grep -v '<none>' | \
        while read -r namespace deploy pvc; do
            echo "Scaling Deployment $deploy in Namespace $namespace to $replica_count replicas... (due to $pvc)"
            kubectl scale deployment "$deploy" --namespace="$namespace" --replicas="$replica_count" --timeout 60s
            echo "$deploy" >> deployments.bak
        done
}

# Function to scale StatefulSets
scale_statefulsets() {
    echo '' > statefulsets.bak
    kubectl get statefulset --all-namespaces -o custom-columns="NAMESPACE:.metadata.namespace,STATEFULSET:.metadata.name" --no-headers | \
        while read -r namespace sts; do
            echo "Scaling Statefulset $sts in Namespace $namespace to $replica_count replicas..."
            kubectl scale statefulset "$sts" --namespace="$namespace" --replicas="$replica_count" --timeout 60s
            echo "$sts" >> statefulsets.bak
        done
}

# Main script
scale_deployments
scale_statefulsets
