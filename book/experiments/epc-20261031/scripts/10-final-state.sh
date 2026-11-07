#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"
# Leave a useful allowed-host policy after the deletion test, and retain its row.
run_step egress-restore-policy kubectl-ate create egress-policy lifecycle-egress -a ate-demo-egress -f "$TASK_EVIDENCE/manifests/egress-hostname-policy.json" -o json
bash "$TASK_EVIDENCE/scripts/capture-database.sh" final
kubectl get pods -A -o wide > "$TASK_EVIDENCE/states/pods-final.txt"
kubectl get events -A --sort-by=.metadata.creationTimestamp > "$TASK_EVIDENCE/states/events-final.txt"
kubectl-ate get actor -A -o json > "$TASK_EVIDENCE/states/actors-final.json"
kubectl -n ate-system logs daemonset/atelet -c atelet --timestamps > "$TASK_EVIDENCE/logs/atelet-lifecycle.log"
for pod in $(kubectl -n ate-demo-counter get pods -o jsonpath='{.items[*].metadata.name}'); do
  kubectl -n ate-demo-counter logs "$pod" -c worker --timestamps > "$TASK_EVIDENCE/logs/$pod-worker.log"
done
