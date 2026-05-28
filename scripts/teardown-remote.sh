#!/usr/bin/env bash
set -euo pipefail
CLUSTER_NAME="cloud-lab"
read -p "This will delete DOKS cluster '$CLUSTER_NAME' and all data. Continue? [y/N] " ans
[[ "$ans" == "y" || "$ans" == "Y" ]] || exit 0
doctl kubernetes cluster delete "$CLUSTER_NAME" --force
echo "Deleted."
