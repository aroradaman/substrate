#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"
actor_uid=$(jq -r '.metadata.uid' "$TASK_EVIDENCE/states/counter-running.json")
capture_network() {
  bash "$TASK_EVIDENCE/scripts/capture-network.sh" "$1" "$actor_uid"
}
capture_network counter-running
run_step counter-suspend-async kubectl-ate suspend actor lifecycle-counter -a ate-demo-counter --mode=async -o json
sed -n '/^{/,$p' "$TASK_EVIDENCE/logs/counter-suspend-async.log" | jq . > "$TASK_EVIDENCE/states/counter-suspended-async.json"
capture_network counter-suspended-async
run_step counter-request-resume curl --silent --show-error --fail --max-time 60 --write-out '\nhttp_code=%{http_code} time_connect=%{time_connect} time_starttransfer=%{time_starttransfer} time_total=%{time_total}\n' http://127.0.0.1:18000/
kubectl-ate get actor lifecycle-counter -a ate-demo-counter -o json > "$TASK_EVIDENCE/states/counter-request-resumed.json"
capture_network counter-request-resumed
run_step counter-suspend-sync kubectl-ate suspend actor lifecycle-counter -a ate-demo-counter --mode=sync -o json
sed -n '/^{/,$p' "$TASK_EVIDENCE/logs/counter-suspend-sync.log" | jq . > "$TASK_EVIDENCE/states/counter-suspended-sync.json"
docker exec substrate-lifecycle-control-plane find /var/lib/ate/snapshots -maxdepth 6 -printf '%y\t%s\t%b\t%p\n' > "$TASK_EVIDENCE/states/snapshot-files-after-sync.tsv"
run_step counter-create-tag kubectl-ate create tag lifecycle-checkpoint -a ate-demo-counter --actor lifecycle-counter -o json
sed -n '/^{/,$p' "$TASK_EVIDENCE/logs/counter-create-tag.log" | jq . > "$TASK_EVIDENCE/states/counter-tag.json"
run_step counter-create-clone kubectl-ate create actor lifecycle-clone -a ate-demo-counter --template counter --tag lifecycle-checkpoint -o json
sed -n '/^{/,$p' "$TASK_EVIDENCE/logs/counter-create-clone.log" | jq . > "$TASK_EVIDENCE/states/counter-clone-created.json"
run_step counter-clone-resume kubectl-ate resume actor lifecycle-clone -a ate-demo-counter -o json
nohup kubectl-ate proxy actor lifecycle-clone 18001:80 -a ate-demo-counter > "$TASK_EVIDENCE/logs/counter-clone-proxy.log" 2>&1 < /dev/null &
echo "$!" > "$TASK_EVIDENCE/counter-clone-proxy.pid"
deadline=$((SECONDS + 60))
until curl --silent --fail --max-time 2 http://127.0.0.1:18001/readyz > /dev/null; do
  if ((SECONDS >= deadline)); then exit 1; fi
  sleep 0.5 # Backoff while polling the readiness condition.
done
run_step counter-clone-request curl --silent --show-error --fail --max-time 60 http://127.0.0.1:18001/
kubectl-ate get actor lifecycle-clone -a ate-demo-counter -o json > "$TASK_EVIDENCE/states/counter-clone-running.json"
run_step counter-original-resume kubectl-ate resume actor lifecycle-counter -a ate-demo-counter -o json
run_step counter-original-request curl --silent --show-error --fail --max-time 60 http://127.0.0.1:18000/
for cycle in 1 2 3; do
  run_step "counter-cycle-$cycle-suspend" kubectl-ate suspend actor lifecycle-counter -a ate-demo-counter --mode=sync -o json
  run_step "counter-cycle-$cycle-request" curl --silent --show-error --fail --max-time 60 --write-out '\nhttp_code=%{http_code} time_starttransfer=%{time_starttransfer} time_total=%{time_total}\n' http://127.0.0.1:18000/
done
kubectl-ate get actor lifecycle-counter -a ate-demo-counter -o json > "$TASK_EVIDENCE/states/counter-final.json"
