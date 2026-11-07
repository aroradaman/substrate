#!/usr/bin/env bash
# Capture only the dedicated kind node. Never read process environments or keys.
set -euo pipefail
source "$(dirname "$0")/common.sh"
stage=${1:?usage: capture-network.sh STAGE [ACTOR_UID]}
actor_uid=${2:-}
[[ "$stage" =~ ^[A-Za-z0-9._-]+$ ]] || { echo 'invalid stage' >&2; exit 2; }
[[ -z "$actor_uid" || "$actor_uid" =~ ^[A-Za-z0-9-]+$ ]] || { echo 'invalid actor UID' >&2; exit 2; }
trace_seconds=${NETWORK_TRACE_SECONDS:-0}
[[ "$trace_seconds" =~ ^[0-9]+$ && "$trace_seconds" -le 30 ]] || { echo 'trace duration must be 0..30 seconds' >&2; exit 2; }
node=substrate-lifecycle-control-plane
stamp=$(date -u +%Y%m%dT%H%M%S)-$$
out="$TASK_EVIDENCE/kernel/network-$stage-$stamp"
node_out="/tmp/substrate-network-$stage-$stamp"
mkdir -p "$out"
printf 'stage=%s\nactor_uid=%s\nnode=%s\nutc=%s\ntrace_seconds=%s\n' "$stage" "$actor_uid" "$node" "$(date -u +%FT%TZ)" "$trace_seconds" > "$out/capture.txt"
# Deliberately omit Pod specs, Secret objects, CRI runtimeSpec and Docker env.
if kubectl get pods -A -o json 2>"$out/pods.stderr" | python3 -c '
import json,sys
p=json.load(sys.stdin)
print(json.dumps({"items":[{"namespace":x["metadata"]["namespace"],"name":x["metadata"]["name"],"uid":x["metadata"]["uid"],"labels":x["metadata"].get("labels",{}),"node":x.get("spec",{}).get("nodeName"),"phase":x.get("status",{}).get("phase"),"podIPs":x.get("status",{}).get("podIPs",[]),"containers":[{"name":c["name"],"containerID":c.get("containerID"),"imageID":c.get("imageID"),"ready":c.get("ready")} for c in x.get("status",{}).get("containerStatuses",[])]} for x in p["items"]]},indent=2))
' > "$out/pods-selected.json"; then
  printf 'pods-selected\t0\n' > "$out/outer-status.tsv"
else
  printf 'pods-selected\tfailed\n' > "$out/outer-status.tsv"
fi
if kubectl get networkpolicies -A -o yaml > "$out/networkpolicies.yaml" 2>"$out/networkpolicies.stderr"; then
  printf 'networkpolicies\t0\n' >> "$out/outer-status.tsv"
else
  printf 'networkpolicies\tfailed\n' >> "$out/outer-status.tsv"
fi
set +e
docker exec -i --user 0 "$node" bash -s -- "$node_out" "$actor_uid" "$trace_seconds" > "$out/collector.log" 2>&1 <<'NODE'
set -uo pipefail
out=$1
actor_uid=$2
trace_seconds=$3
mkdir -p "$out"
status="$out/status.tsv"
printf 'utc\tprobe\texit_code\n' > "$status"
run() {
  local name=$1 rc
  shift
  mkdir -p "$(dirname "$out/$name")"
  timeout 25 "$@" > "$out/$name" 2> "$out/$name.stderr"
  rc=$?
  printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$name" "$rc" >> "$status"
  return 0
}
run tools.txt bash -c 'uname -a; for t in bash jq nft nsenter ip ss crictl ps findmnt stat tcpdump; do command -v "$t" || true; done; ip -Version; nft --version; nsenter --version; ss --version; crictl --version; dpkg-query -W iproute2 nftables util-linux procps jq tcpdump 2>&1'
run node/ns.txt bash -c 'for n in net mnt pid user cgroup; do printf "%s " "$n"; readlink "/proc/self/ns/$n"; done'
run node/mount-cgroup.txt findmnt -T /sys/fs/cgroup -o TARGET,FSTYPE,OPTIONS
run node/cni-files.txt bash -c 'find /etc/cni/net.d -maxdepth 1 -type f -printf "%f\n" 2>/dev/null; find /opt/cni/bin -maxdepth 1 -type f -printf "%f\n" 2>/dev/null'
run node/process-tree.txt ps -e -o pid,ppid,comm
run node/cri-selected.json bash -o pipefail -c 'crictl ps -o json | jq "{containers:[.containers[]|{id,podSandboxId,metadata,state,labels,imageRef}]}"'
# No physical epc-host or Docker-parent cgroup is traversed. '/' means node root.
run node/cgroup-root.txt bash -c 'for f in cgroup.type cgroup.controllers cgroup.subtree_control memory.max memory.high memory.current memory.events memory.stat cpu.max cpu.weight cpu.stat pids.max pids.current; do if test -r "/sys/fs/cgroup/$f"; then printf "[%s]\n" "$f"; cat "/sys/fs/cgroup/$f"; else printf "[%s unavailable]\n" "$f"; fi; done'
net_capture() {
  local label=$1 nsfile=$2
  local -a enter=(nsenter "--net=$nsfile" --)
  run "$label/ns-inode.txt" stat -Lc 'inode=%i device=%d type=%F' "$nsfile"
  run "$label/link.txt" "${enter[@]}" ip -details -statistics link show
  run "$label/link.json" "${enter[@]}" ip -j -d link show
  run "$label/address.json" "${enter[@]}" ip -j address show
  run "$label/route4.txt" "${enter[@]}" ip -4 route show table all
  run "$label/route6.txt" "${enter[@]}" ip -6 route show table all
  run "$label/rules.txt" "${enter[@]}" ip rule show
  run "$label/neighbours.txt" "${enter[@]}" ip neighbour show
  run "$label/nft.txt" "${enter[@]}" nft -a list ruleset
  run "$label/nft.json" "${enter[@]}" nft -j -a list ruleset
  run "$label/sockets.txt" "${enter[@]}" ss -H -a -n -p -e -t -u -x
  run "$label/sysctls.txt" "${enter[@]}" bash -c 'for f in /proc/sys/net/ipv4/ip_unprivileged_port_start /proc/sys/net/ipv4/conf/*/{forwarding,accept_redirects,route_localnet,accept_local,accept_source_route,rp_filter} /proc/sys/net/ipv6/conf/*/{forwarding,accept_ra,accept_redirects}; do test -r "$f" || continue; printf "%s=" "$f"; cat "$f"; done'
  # ip JSON reports ifindex/link_index across netns. A node-mounted sysfs would
  # show node interfaces, so do not pretend /sys/class/net reflects this setns.
  if ((trace_seconds > 0)); then
    run "$label/packet-headers.txt" timeout "$trace_seconds" "${enter[@]}" tcpdump -ni any -nn -tttt -q -s 96 -c 100 'tcp or udp port 53'
  fi
}
cgroup_capture() {
  local pid=$1 label=$2 rel current
  rel=$(awk -F: '$1 == "0" {print $3}' "/proc/$pid/cgroup")
  if [[ -z "$rel" || "$rel" == *'..'* ]]; then
    printf 'No usable node-relative cgroup-v2 path for PID %s: %s\n' "$pid" "$rel" > "$out/$label/cgroup-unavailable.txt"
    return
  fi
  current=$rel
  while :; do
    local key=${current#/}
    [[ -n "$key" ]] || key=_node_root
    run "cgroups/$key/values.txt" bash -c 'd=$1; printf "node_relative_path=%s\n" "$2"; if ! test -d "$d"; then echo "CGROUP PATH ABSENT"; exit 1; fi; for f in cgroup.type cgroup.controllers cgroup.subtree_control cgroup.procs cgroup.threads memory.max memory.high memory.current memory.events memory.events.local memory.stat memory.pressure cpu.max cpu.weight cpu.stat pids.max pids.current; do if test -r "$d/$f"; then printf "[%s]\n" "$f"; cat "$d/$f"; else printf "[%s unavailable]\n" "$f"; fi; done' bash "/sys/fs/cgroup$current" "$current"
    printf '%s\t%s\n' "$pid" "$current" >> "$out/cgroup-ancestry.tsv"
    [[ "$current" == / ]] && break
    current=${current%/*}
    [[ -n "$current" ]] || current=/
  done
}
process_capture() {
  local pid=$1 label=$2
  run "$label/identity.txt" bash -c 'p=$1; printf "pid=%s\n" "$p"; cat "/proc/$p/comm"; readlink "/proc/$p/exe"; for n in net mnt pid user cgroup ipc uts; do printf "%s " "$n"; readlink "/proc/$p/ns/$n"; done; awk "/^(Name|State|Pid|PPid|NSpid|NStgid|Uid|Gid|Threads|CapInh|CapPrm|CapEff|CapBnd|NoNewPrivs|Seccomp):/" "/proc/$p/status"; cat "/proc/$p/cgroup"' bash "$pid"
  run "$label/fds.txt" bash -c 'p=$1; regular=0; for f in /proc/"$p"/fd/*; do t=$(readlink "$f") || continue; case "$t" in socket:*|pipe:*|net:*|mnt:*|pid:*|user:*|cgroup:*|anon_inode:*) printf "%s\t%s\n" "${f##*/}" "$t";; *) regular=$((regular+1));; esac; done; printf "other_path_fds_count=%s (paths and contents omitted)\n" "$regular"' bash "$pid"
  run "$label/mounts.txt" awk '$0 ~ /netns|cgroup|\/var\/lib\/ate|\/run\/ate|overlay/ {print}' "/proc/$pid/mountinfo"
  cgroup_capture "$pid" "$label"
}
net_capture node/network /proc/self/ns/net
# Inspect each external atenet Pod network once, independent of actor-local -at.
gateways=$(crictl ps -o json | jq -r '[.containers[] | select((.labels["io.kubernetes.pod.namespace"] == "ate-system") and (.labels["io.kubernetes.pod.name"] | startswith("atenet-")))] | unique_by(.podSandboxId)[] | [.id,.labels["io.kubernetes.pod.name"],.podSandboxId] | @tsv')
printf 'container_id\tpod\tsandbox_id\n%s\n' "$gateways" > "$out/external-gateways.tsv"
while IFS=$'\t' read -r gateway_cid gateway_pod gateway_sandbox; do
  [[ -n "$gateway_cid" ]] || continue
  gateway_pid=$(crictl inspect "$gateway_cid" | jq -r '.info.pid // empty')
  if [[ "$gateway_pid" =~ ^[1-9][0-9]*$ && -d "/proc/$gateway_pid" ]]; then
    net_capture "external-gateways/$gateway_pod/network" "/proc/$gateway_pid/ns/net"
    process_capture "$gateway_pid" "external-gateways/$gateway_pod/container-pid-$gateway_pid"
  else
    printf '%s PID unavailable: %s\n' "$gateway_pod" "$gateway_pid" >> "$out/external-gateways-unavailable.txt"
  fi
done <<< "$gateways"
workers=$(crictl ps -o json | jq -r '.containers[] | select(.metadata.name == "worker") | [.id,.labels["io.kubernetes.pod.namespace"],.labels["io.kubernetes.pod.name"],.labels["io.kubernetes.pod.uid"],.podSandboxId] | @tsv')
rc=$?
printf '%s\tworker-discovery\t%s\n' "$(date -u +%FT%TZ)" "$rc" >> "$status"
printf 'container_id\tnamespace\tpod\tpod_uid\tsandbox_id\n%s\n' "$workers" > "$out/workers.tsv"
if [[ -z "$workers" ]]; then
  printf 'No running CRI container named worker was found. No actor namespace inspection was possible.\n' > "$out/no-workers.txt"
fi
while IFS=$'\t' read -r cid namespace pod pod_uid sandbox; do
  [[ -n "$cid" ]] || continue
  label="workers/$namespace-$pod"
  mkdir -p "$out/$label"
  run "$label/cri-selected.json" bash -o pipefail -c 'crictl inspect "$1" | jq "{status:{id:.status.id,metadata:.status.metadata,state:.status.state,labels:.status.labels,imageRef:.status.imageRef},pid:.info.pid,runtimeType:.info.runtimeType}"' bash "$cid"
  pid=$(crictl inspect "$cid" | jq -r '.info.pid // empty')
  if [[ ! "$pid" =~ ^[1-9][0-9]*$ || ! -d "/proc/$pid" ]]; then
    printf 'Worker PID unavailable or exited: %s\n' "$pid" > "$out/$label/pid-unavailable.txt"
    continue
  fi
  printf '%s\t%s\t%s\t%s\n' "$namespace" "$pod" "$cid" "$pid" >> "$out/worker-pids.tsv"
  process_capture "$pid" "$label/init-pid-$pid"
  net_capture "$label/pod-network" "/proc/$pid/ns/net"
  # Access the bind mounts through the worker's root/mount view, while retaining
  # the node mount namespace so distroless images need no inspection binaries.
  nsdir="/proc/$pid/root/run/netns"
  run "$label/named-netns.txt" bash -c 'd=$1; if ! test -d "$d"; then echo "worker /run/netns absent"; exit 0; fi; find "$d" -mindepth 1 -maxdepth 1 -printf "%f\n"; for f in "$d"/*; do test -e "$f" || continue; printf "%s " "${f##*/}"; stat -Lc "inode=%i device=%d type=%F" "$f"; done' bash "$nsdir"
  if [[ -n "$actor_uid" ]]; then
    names=("worker-actor:$actor_uid" "worker-actor:$actor_uid-at")
  else
    mapfile -t names < <(find "$nsdir" -mindepth 1 -maxdepth 1 -name 'worker-actor:*' -printf '%f\n' 2>/dev/null | sort)
  fi
  for name in "${names[@]}"; do
    [[ "$name" =~ ^worker-actor:[A-Za-z0-9-]+$ ]] || continue
    if [[ -e "$nsdir/$name" ]]; then
      net_capture "$label/namespaces/$name" "$nsdir/$name"
    else
      mkdir -p "$out/$label/namespaces/$name"
      printf 'NAMESPACE ABSENT\nname=%s\nworker_pid=%s\nutc=%s\nThis may be expected after suspension or on a different worker.\n' "$name" "$pid" "$(date -u +%FT%TZ)" > "$out/$label/namespaces/$name/absent.txt"
    fi
  done
  worker_cgroup=$(awk -F: '$1 == "0" {print $3}' "/proc/$pid/cgroup")
  # Delegate moves processes to a worker leaf; actor leaves are its siblings.
  # Scope comes from the actual node-relative path, not the source comment's
  # "pod scope" terminology: CRI may delegate only the container scope.
  worker_scope=$worker_cgroup
  [[ "$worker_scope" != */worker ]] || worker_scope=${worker_scope%/worker}
  printf 'worker_process_cgroup=%s\ndelegated_scope=%s\n' "$worker_cgroup" "$worker_scope" > "$out/$label/delegated-scope.txt"
  # Include actual worker, Sentry and gofer processes throughout that scope.
  # Do not assume a process's role from its cgroup name.
  for proc in /proc/[0-9]*; do
    other=${proc##*/}
    [[ "$other" != "$pid" ]] || continue
    cg=$(awk -F: '$1 == "0" {print $3}' "$proc/cgroup" 2>/dev/null) || continue
    [[ -n "$worker_scope" && ( "$cg" == "$worker_scope" || "$cg" == "$worker_scope/"* ) ]] || continue
    comm=$(cat "$proc/comm" 2>/dev/null) || continue
    case "$comm" in ateworker*|runsc*|gvisor*|systrap*|exe|cloud-hyper*|virtiofsd)
      process_capture "$other" "$label/processes/pid-$other"
      # Roles are only extracted from known runsc argv tokens, never dumped.
      role=unknown
      platform=unspecified
      while IFS= read -r -d '' arg; do
        case "$arg" in boot) role=sentry;; gofer) role=gofer;; --platform=systrap|--platform=kvm|--platform=ptrace) platform=${arg#--platform=};; esac
      done < "$proc/cmdline"
      printf '%s\t%s\t%s\t%s\t%s\n' "$other" "$comm" "$role" "$platform" "$cg" >> "$out/$label/runtime-processes.tsv"
      ;;
    esac
  done
  run "$label/cgroup-descendants.txt" find "/sys/fs/cgroup$worker_scope" -maxdepth 5 -type d
  # Capture leaf controls even when runsc created empty container markers.
  while IFS= read -r directory; do
    relative=${directory#/sys/fs/cgroup}
    run "cgroups/${relative#/}/leaf.txt" bash -c 'for f in cgroup.type cgroup.controllers cgroup.subtree_control cgroup.procs memory.max memory.high memory.current memory.events cpu.max cpu.weight cpu.stat pids.max pids.current; do if test -r "$1/$f"; then printf "[%s]\n" "$f"; cat "$1/$f"; fi; done' bash "$directory"
  done < <(find "/sys/fs/cgroup$worker_scope" -mindepth 1 -maxdepth 5 -type d 2>/dev/null)
done <<< "$workers"
printf 'Capture complete: %s\n' "$out"
NODE
collector_rc=$?
set -e
printf 'node-collector\t%s\n' "$collector_rc" >> "$out/outer-status.tsv"
mkdir -p "$out/node"
# kind's /tmp mount is visible inside the node but not reliably to docker cp.
# Stream the collector-created tree through the same namespace view.
if docker exec --user 0 "$node" tar -C "$node_out" -cf - . 2>"$out/node-tar.stderr" | tar -C "$out/node" -xf - 2>"$out/extract.stderr"; then
  printf 'node-tar-copy\t0\n' >> "$out/outer-status.tsv"
else
  printf 'node-tar-copy\tfailed\n' >> "$out/outer-status.tsv"
  exit 1
fi
# Leave the small node-side evidence directory intact for auditability.
printf '%s\n' "$out"
exit "$collector_rc"
