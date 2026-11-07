#!/usr/bin/env bash
set -euo pipefail
TASK_SOURCE=/home/daman/substrate-lifecycle-20261031
TASK_EVIDENCE=/home/daman/substrate-lifecycle-evidence-20261031
export PATH="$TASK_EVIDENCE/bin:/usr/local/go/bin:/home/daman/go/bin:$PATH"
export KUBECONFIG="$TASK_EVIDENCE/kubeconfig"
export KIND_CLUSTER_NAME=substrate-lifecycle
export KIND_REGISTRY_PORT=5002
export KUBECTL_CONTEXT=kind-substrate-lifecycle
export ATE_INSTALL_KIND=true
export GOMAXPROCS=8
mkdir -p "$TASK_EVIDENCE"/{bin,logs,manifests,states,metrics,kernel}
cd "$TASK_SOURCE"
run_step() {
  local step=$1
  shift
  local started ended step_exit_code
  started=$(date -u +%FT%TZ)
  printf '%s\t%s\t' "$started" "$step" >> "$TASK_EVIDENCE/commands.tsv"
  printf '%q ' "$@" >> "$TASK_EVIDENCE/commands.tsv"
  printf '\n' >> "$TASK_EVIDENCE/commands.tsv"
  set +e
  /usr/bin/time -v -o "$TASK_EVIDENCE/metrics/$step.time.txt" "$@" > "$TASK_EVIDENCE/logs/$step.log" 2>&1
  step_exit_code=$?
  set -e
  ended=$(date -u +%FT%TZ)
  printf '%s\t%s\t%s\t%s\n' "$step" "$started" "$ended" "$step_exit_code" >> "$TASK_EVIDENCE/results.tsv"
  tail -n 25 "$TASK_EVIDENCE/logs/$step.log"
  return "$step_exit_code"
}
