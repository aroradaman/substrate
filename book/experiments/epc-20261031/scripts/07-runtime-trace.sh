#!/usr/bin/env bash
# Trace only checkpoint. Following runsc sandbox creation with ptrace disturbed
# systrap startup in the first attempt, so restore happens after detachment.
set -euo pipefail
source "$(dirname "$0")/common.sh"
node=substrate-lifecycle-control-plane
out="$TASK_EVIDENCE/kernel/runtime-trace"
if [[ -d "$out" ]]; then
  mv "$out" "$out-previous-$(date -u +%Y%m%dT%H%M%S)"
fi
mkdir -p "$out"
kubectl-ate get actor lifecycle-counter -a ate-demo-counter -o json > "$out/actor-before.json"
actor_uid=$(jq -r '.metadata.uid' "$out/actor-before.json")
pod=$(jq -r '.status.workerAssignment.workerPod' "$out/actor-before.json")
container=$(docker exec "$node" crictl ps -o json | jq -r --arg pod "$pod" '.containers[] | select(.metadata.name == "worker" and .labels["io.kubernetes.pod.name"] == $pod) | .id')
init_pid=$(docker exec "$node" crictl inspect "$container" | jq -r '.info.pid')
# CRI reports the entrypoint/reaper. The already-running daemon is its child;
# strace -f on the reaper alone would miss that existing child's operations.
worker_pid=$(docker exec "$node" ps -e -o pid=,ppid=,comm= | awk -v parent="$init_pid" '$2 == parent && $3 ~ /^ateworker/ {print $1}')
[[ "$worker_pid" =~ ^[1-9][0-9]*$ ]] || { echo 'could not identify one worker daemon' >&2; exit 1; }
printf 'node=%s\nactor_uid=%s\nworker_pod=%s\nentrypoint_pid_in_node=%s\nworker_pid_in_node=%s\n' "$node" "$actor_uid" "$pod" "$init_pid" "$worker_pid" > "$out/identity.txt"
docker exec "$node" strace --version > "$out/strace-version.txt"
# Read/write payloads and process environments are deliberately not traced.
syscalls=clone,clone3,execve,wait4,waitid,exit_group,setns,unshare,mount,umount2,pivot_root,seccomp,prctl,pidfd_open,pidfd_send_signal,memfd_create,userfaultfd,fsopen,fsconfig,fsmount,move_mount,open_tree,cachestat,fadvise64,fdatasync,copy_file_range,renameat2,unlinkat
printf 'strace -f -ttt -T -s 128 -e trace=%s -p %s\n' "$syscalls" "$worker_pid" > "$out/command.txt"
docker exec "$node" timeout --signal=INT 20 strace -f -qq -ttt -T -s 128 -e "trace=$syscalls" -p "$worker_pid" -o /tmp/substrate-lifecycle-strace.txt > "$out/strace.stdout" 2> "$out/strace.stderr" &
trace_job=$!
# Wait for an actual ptrace attachment, with a bounded deadline.
deadline=$((SECONDS + 5))
until docker exec "$node" awk '/^TracerPid:/ {exit ($2 == 0)}' "/proc/$worker_pid/status"; do
  if ((SECONDS >= deadline)); then
    echo 'strace did not attach' >&2
    exit 1
  fi
  sleep 0.1
done
run_step counter-diagnostic-suspend kubectl-ate suspend actor lifecycle-counter -a ate-demo-counter --mode=sync -o json
set +e
wait "$trace_job"
trace_status=$?
set -e
printf '%s\n' "$trace_status" > "$out/tracer-exit-status.txt"
docker exec "$node" cat /tmp/substrate-lifecycle-strace.txt > "$out/syscalls.txt"
run_step counter-diagnostic-request curl --silent --show-error --fail --max-time 60 http://127.0.0.1:18000/
kubectl-ate get actor lifecycle-counter -a ate-demo-counter -o json > "$out/actor-after.json"
