#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"
run_step deploy-substrate ate-setup deploy ate-system \
  --kind --kind-cluster-name=substrate-lifecycle --ko-docker-repo=localhost:5002 \
  --sandbox-classes=gvisor \
  --credential-provider='{"name":"k8s.io"}' \
  --ingress-allowed-spiffe-ids=spiffe://cluster.local/ns/ate-system/sa/atenet-client
run_step deploy-counter ate-setup deploy demo counter \
  --kind --kind-cluster-name=substrate-lifecycle --ko-docker-repo=localhost:5002
run_step deploy-egress ate-setup deploy demo egress \
  --kind --kind-cluster-name=substrate-lifecycle --ko-docker-repo=localhost:5002
kubectl get pods -A -o wide > "$TASK_EVIDENCE/states/pods-after-deploy.txt"
kubectl get pods -A -o json > "$TASK_EVIDENCE/states/pods-after-deploy.json"
