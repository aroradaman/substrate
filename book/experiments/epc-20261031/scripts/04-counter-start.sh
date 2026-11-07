#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"
run_step counter-create kubectl-ate create actor lifecycle-counter -a ate-demo-counter --template counter -o json
sed -n '/^{/,$p' "$TASK_EVIDENCE/logs/counter-create.log" | jq . > "$TASK_EVIDENCE/states/counter-created.json"
run_step counter-resume-first kubectl-ate resume actor lifecycle-counter -a ate-demo-counter -o json
kubectl-ate get actor lifecycle-counter -a ate-demo-counter -o json > "$TASK_EVIDENCE/states/counter-running.json"
nohup kubectl-ate proxy actor lifecycle-counter 18000:80 -a ate-demo-counter > "$TASK_EVIDENCE/logs/counter-proxy.log" 2>&1 < /dev/null &
echo "$!" > "$TASK_EVIDENCE/counter-proxy.pid"
deadline=$((SECONDS + 60))
until curl --silent --fail --max-time 2 http://127.0.0.1:18000/readyz > /dev/null; do
  if ((SECONDS >= deadline)); then
    echo "counter proxy did not become ready" >&2
    exit 1
  fi
  sleep 0.5 # Backoff while polling the readiness condition.
done
for request in 1 2 3; do
  run_step "counter-before-$request" curl --silent --show-error --fail --max-time 30 http://127.0.0.1:18000/
done
kubectl-ate get worker -o json > "$TASK_EVIDENCE/states/workers-counter-running.json"
