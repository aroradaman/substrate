#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"
run_step create-kind hack/create-kind-cluster.sh
cp bin/kind-config.yaml "$TASK_EVIDENCE/manifests/kind-config.yaml"
kubectl get nodes -o wide > "$TASK_EVIDENCE/states/nodes-initial.txt"
kubectl get nodes -o json > "$TASK_EVIDENCE/states/nodes-initial.json"
docker inspect substrate-lifecycle-control-plane --format '{{.Config.Image}} {{.Image}}' > "$TASK_EVIDENCE/kind-node-image.txt"
