#!/bin/sh
echo "Depoyment $2 in $1"
NAMESPACE=$1
DEPLOYMENT=$2


PVC=$(kubectl -n $1 get deploy $2 -o json | jq -r '.spec.template.spec.volumes.[].persistentVolumeClaim.claimName | select( . != null )'  | grep -v 'torrents-v2' | fzf)
echo "PVC $PVC"

# Check if the input_string ends with '-v' followed by a single digit
if [[ $PVC =~ -v[0-9]$ ]]; then
  # Extract the numeric part and increment it
  numeric_part="${PVC: -1}"
  new_numeric_part=$((numeric_part + 1))

  # Replace the numeric part with the incremented value
  NEW_PVC="${PVC%$numeric_part}$new_numeric_part"
else
  # If it doesn't end with '-v' followed by a single digit, append '-v1'
  NEW_PVC="${PVC}-v1"
fi

echo "Will create $NEW_PVC"
read -p "Ok to copy $PVC to $NEW_PVC?" -n 1 -r
echo    # (optional) move to a new line
if [[ ! $REPLY =~ ^[Yy]$ ]]
then
    [[ "$0" = "$BASH_SOURCE" ]] && exit 1 || return 1 # handle exits from shell or function but don't exit interactive shell
fi

# Create a PVC YAML file dynamically with the PVC name
cat <<EOF > pvc.yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: $NEW_PVC
  namespace: $NAMESPACE
spec:
  storageClassName: nfs-client
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 1Mi
EOF

echo "Creating $NEW_PVC in $NAMESPACE";
# Apply the PVC YAML file using kubectl
kubectl apply -f pvc.yaml

echo "Scaling down $DEPLOYMENT";
kubectl -n $NAMESPACE scale --replicas=0 deploy/$DEPLOYMENT --timeout=120s


echo "Copying data for $DEPLOYMENT";
kubectl -n $NAMESPACE run -it --rm copy-pod --image=ghcr.io/vaskozl/lwp-simple:9-minimal --restart=Never --overrides='
{
  "apiVersion": "v1",
  "spec": {
    "volumes": [
      {
        "name": "source-volume",
        "persistentVolumeClaim": {
          "claimName": "'$PVC'"
        }
      },
      {
        "name": "destination-volume",
        "persistentVolumeClaim": {
          "claimName": "'$NEW_PVC'"
        }
      }
    ],
    "containers": [
      {
        "name": "copy-container",
        "image": "ghcr.io/vaskozl/lwp-simple:9-minimal",
        "command": ["/bin/sh"],
        "args": ["-c", "cp -a /source-path/. /destination-path/ && du -sh /source-path && du -sh /destination-path"],
        "volumeMounts": [
          {
            "name": "source-volume",
            "mountPath": "/source-path"
          },
          {
            "name": "destination-volume",
            "mountPath": "/destination-path"
          }
        ]
      }
    ]
  }
}'


echo "Scaling up $DEPLOYMENT";
kubectl -n $NAMESPACE scale --replicas=1 deploy/$DEPLOYMENT --timeout=120s
