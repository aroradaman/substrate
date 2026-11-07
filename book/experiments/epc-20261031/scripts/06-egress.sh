#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=book/experiments/epc-20261031/scripts/common.sh
source "$(dirname "$0")/common.sh"

# --prepare builds only the origin fixture. The default invocation starts the
# experiment after the parent confirms demo deployment has completed.
EGRESS_DIR="$TASK_EVIDENCE/egress"
mkdir -p "$EGRESS_DIR"/{requests,responses,states,logs}
EGRESS_ACTOR=lifecycle-egress
EGRESS_ATESPACE=ate-demo-egress
ORIGIN_HOST=origin.lifecycle-target.svc.cluster.local
ORIGIN_BODY=substrate-lifecycle-origin-20261031
ORIGIN_REFERENCE_FILE="$EGRESS_DIR/origin-image.txt"

prepare_origin() {
  export KO_DOCKER_REPO=localhost:5002
  run_step egress-origin-build hack/run-tool.sh ko publish --platform=linux/amd64 ./internal/e2e/fixtures/testserver
  grep -E '^localhost:5002/.+@sha256:[0-9a-f]{64}$' "$TASK_EVIDENCE/logs/egress-origin-build.log" | tail -n 1 > "$ORIGIN_REFERENCE_FILE"
  test -s "$ORIGIN_REFERENCE_FILE"
  local reference digest
  reference=$(cat "$ORIGIN_REFERENCE_FILE")
  run_step egress-origin-digest go run github.com/google/go-containerregistry/cmd/crane@latest digest --insecure "$reference"
  digest=$(grep -E '^sha256:[0-9a-f]{64}$' "$TASK_EVIDENCE/logs/egress-origin-digest.log" | tail -n 1)
  test "$digest" = "${reference##*@}"
  printf '%s\n' "$digest" > "$EGRESS_DIR/origin-verified-digest.txt"
  git rev-parse HEAD > "$EGRESS_DIR/source-commit.txt"
}

if [[ "${1:-}" == --prepare ]]; then
  prepare_origin
  exit 0
fi
if [[ -n "${1:-}" ]]; then
  printf 'Usage: %s [--prepare]\n' "$0" >&2
  exit 2
fi
test -s "$ORIGIN_REFERENCE_FILE"
test -s "$EGRESS_DIR/origin-verified-digest.txt"
ORIGIN_REFERENCE=$(cat "$ORIGIN_REFERENCE_FILE")
PROXY_PID=
ORIGIN_PROXY_PID=

capture_final() {
  local status=$?
  trap - EXIT
  set +e
  kubectl ate get actor "$EGRESS_ACTOR" -a "$EGRESS_ATESPACE" -o json > "$EGRESS_DIR/states/actor-final.json" 2> "$EGRESS_DIR/logs/actor-final.err"
  kubectl -n ate-system logs deploy/atenet-egress -c ext-proc --since=30m --timestamps > "$EGRESS_DIR/logs/gateway-ext-proc.log" 2>&1
  kubectl -n ate-system logs deploy/atenet-egress -c envoy --since=30m --timestamps > "$EGRESS_DIR/logs/gateway-envoy.log" 2>&1
  kubectl -n lifecycle-target logs deploy/origin --timestamps > "$EGRESS_DIR/logs/origin.log" 2>&1
  kubectl -n lifecycle-target get pods,svc -o wide > "$EGRESS_DIR/states/origin-final.txt" 2>&1
  if [[ -n "$PROXY_PID" ]]; then kill "$PROXY_PID"; wait "$PROXY_PID"; fi
  if [[ -n "$ORIGIN_PROXY_PID" ]]; then kill "$ORIGIN_PROXY_PID"; wait "$ORIGIN_PROXY_PID"; fi
  printf '%s\t%s\n' "$(date -u +%FT%TZ)" "$status" > "$EGRESS_DIR/exit-status.tsv"
  exit "$status"
}
trap capture_final EXIT

wait_http() {
  local name=$1 url=$2 deadline=$((SECONDS + 60)) attempt=0 code
  while (( SECONDS < deadline )); do
    attempt=$((attempt + 1))
    if code=$(curl --silent --show-error --connect-timeout 2 --max-time 3 -o "$EGRESS_DIR/responses/$name-$attempt.body" -w '%{http_code}' "$url" 2> "$EGRESS_DIR/logs/$name-$attempt.err") && [[ "$code" == 200 ]]; then
      printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$name" "$attempt" >> "$EGRESS_DIR/readiness.tsv"
      return 0
    fi
    sleep 0.5
  done
  printf 'Timed out waiting for %s at %s\n' "$name" "$url" >&2
  return 1
}

policy_denial() {
  local code=$1 file=$2
  if [[ "$code" == 403 ]] && grep -Eq 'egress denied|actor egress policy denied' "$file"; then return 0; fi
  [[ "$code" == 502 ]] && grep -q 'request failed' "$file"
}

probe_until() {
  local name=$1 expectation=$2 url=$3 limit=${4:-60}
  local deadline=$((SECONDS + limit)) attempt=0 code elapsed _connected _bytes curl_status start_utc start_ns matched
  jq -n --arg url "$url" '{url:$url,http1:true}' > "$EGRESS_DIR/requests/$name.json"
  while (( SECONDS < deadline )); do
    attempt=$((attempt + 1))
    start_utc=$(date -u +%FT%T.%NZ)
    start_ns=$(date +%s%N)
    curl_status=0
    curl --silent --show-error --connect-timeout 3 --max-time 20 \
      --request POST --header 'Content-Type: application/json' --header 'Connection: close' \
      --data-binary "@$EGRESS_DIR/requests/$name.json" \
      --dump-header "$EGRESS_DIR/responses/$name-$attempt.headers" \
      --output "$EGRESS_DIR/responses/$name-$attempt.json" \
      --write-out '%{http_code}\t%{time_total}\t%{time_connect}\t%{size_download}\n' \
      http://127.0.0.1:18080/ > "$EGRESS_DIR/responses/$name-$attempt.curl.tsv" \
      2> "$EGRESS_DIR/logs/$name-$attempt.err" || curl_status=$?
    IFS=$'\t' read -r code elapsed _connected _bytes < "$EGRESS_DIR/responses/$name-$attempt.curl.tsv"
    matched=false
    if [[ "$curl_status" == 0 ]]; then
      if [[ "$expectation" == allow && "$code" == 200 ]] && jq -e --arg body "$ORIGIN_BODY" '.statusCode == 200 and .body == $body' "$EGRESS_DIR/responses/$name-$attempt.json" > /dev/null; then matched=true; fi
      if [[ "$expectation" == deny ]] && policy_denial "$code" "$EGRESS_DIR/responses/$name-$attempt.json"; then matched=true; fi
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$attempt" "$start_utc" "$start_ns" "$code" "$elapsed" "$curl_status" "$expectation" "$matched" >> "$EGRESS_DIR/probes.tsv"
    if [[ "$matched" == true ]]; then
      cp "$EGRESS_DIR/responses/$name-$attempt.json" "$EGRESS_DIR/responses/$name-final.json"
      printf '%s: HTTP %s after %s probe(s), request %ss\n' "$name" "$code" "$attempt" "$elapsed"
      cat "$EGRESS_DIR/responses/$name-final.json"
      return 0
    fi
    sleep 0.5
  done
  printf '%s: did not observe %s within bounded polling window\n' "$name" "$expectation" >&2
  return 1
}

snapshot_actor() {
  local label=$1
  kubectl ate get actor "$EGRESS_ACTOR" -a "$EGRESS_ATESPACE" -o json > "$EGRESS_DIR/states/actor-$label.json"
  jq -e --arg name "$EGRESS_ACTOR" '.metadata.name == $name and (.metadata.uid | length > 0)' "$EGRESS_DIR/states/actor-$label.json" > /dev/null
}

cat > "$TASK_EVIDENCE/manifests/egress-origin.yaml" <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: lifecycle-target
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: origin
  namespace: lifecycle-target
spec:
  replicas: 1
  selector:
    matchLabels: {app: lifecycle-origin}
  template:
    metadata:
      labels: {app: lifecycle-origin}
    spec:
      containers:
      - name: origin
        image: $ORIGIN_REFERENCE
        args: [http, --listen=:8080, --body=$ORIGIN_BODY]
        ports:
        - {name: http, containerPort: 8080}
        readinessProbe:
          httpGet: {path: /healthz, port: http}
        resources:
          requests: {cpu: 10m, memory: 32Mi}
          limits: {cpu: 250m, memory: 128Mi}
---
apiVersion: v1
kind: Service
metadata:
  name: origin
  namespace: lifecycle-target
spec:
  selector: {app: lifecycle-origin}
  ports:
  - {name: http, port: 80, targetPort: http}
EOF
run_step egress-origin-deploy kubectl apply -f "$TASK_EVIDENCE/manifests/egress-origin.yaml"
run_step egress-origin-ready kubectl -n lifecycle-target rollout status deployment/origin --timeout=120s
kubectl -n lifecycle-target get deployment origin -o json > "$EGRESS_DIR/states/origin-deployment.json"
kubectl -n lifecycle-target get pods -l app=lifecycle-origin -o json > "$EGRESS_DIR/states/origin-pods.json"
kubectl -n lifecycle-target get svc origin -o json > "$EGRESS_DIR/states/origin-service.json"
ORIGIN_IP=$(jq -r '.spec.clusterIP' "$EGRESS_DIR/states/origin-service.json")
kubectl -n lifecycle-target port-forward svc/origin 18081:80 > "$EGRESS_DIR/logs/origin-port-forward.log" 2>&1 &
ORIGIN_PROXY_PID=$!
wait_http origin-control http://127.0.0.1:18081/healthz
run_step egress-create-actor kubectl ate create actor "$EGRESS_ACTOR" -a "$EGRESS_ATESPACE" --template egress
snapshot_actor created
ACTOR_UID=$(jq -er '.metadata.uid' "$EGRESS_DIR/states/actor-created.json")
printf '%s\n' "$ACTOR_UID" > "$EGRESS_DIR/actor-uid.txt"
kubectl ate proxy actor "$EGRESS_ACTOR" 18080:80 -a "$EGRESS_ATESPACE" > "$EGRESS_DIR/logs/actor-proxy.log" 2>&1 &
PROXY_PID=$!
wait_http actor-route http://127.0.0.1:18080/readyz
snapshot_actor running-no-policy
kubectl ate get egress-policy "$EGRESS_ACTOR" -a "$EGRESS_ATESPACE" -o json > "$EGRESS_DIR/states/policy-absent.json" 2> "$EGRESS_DIR/logs/policy-absent.err"
printf 'name\tattempt\tstart_utc\tstart_unix_ns\thttp_code\ttime_total_s\tcurl_status\texpectation\tmatched\n' > "$EGRESS_DIR/probes.tsv"
probe_until no-policy deny "http://$ORIGIN_IP/healthz"
jq -n --arg host "$ORIGIN_HOST" '{rules:[{http:{hostnames:[$host],ports:{numbers:[80]}}}]}' > "$TASK_EVIDENCE/manifests/egress-hostname-policy.json"
run_step egress-create-policy kubectl ate create egress-policy "$EGRESS_ACTOR" -a "$EGRESS_ATESPACE" -f "$TASK_EVIDENCE/manifests/egress-hostname-policy.json"
kubectl ate get egress-policy "$EGRESS_ACTOR" -a "$EGRESS_ATESPACE" -o json > "$EGRESS_DIR/states/policy-created.json"
probe_until hostname-allowed allow "http://$ORIGIN_HOST/healthz"
probe_until same-origin-ip-denied deny "http://$ORIGIN_IP/healthz"
snapshot_actor running-with-policy
"$TASK_EVIDENCE/scripts/capture-network.sh" egress-running "$ACTOR_UID"
run_step egress-sync-suspend kubectl ate suspend actor "$EGRESS_ACTOR" -a "$EGRESS_ATESPACE" --mode=sync
snapshot_actor suspended
jq -e '.status.state == "ACTOR_STATE_SUSPENDED"' "$EGRESS_DIR/states/actor-suspended.json" > /dev/null
probe_until hostname-after-resume allow "http://$ORIGIN_HOST/healthz"
snapshot_actor resumed
"$TASK_EVIDENCE/scripts/capture-network.sh" egress-resumed "$ACTOR_UID"
probe_until same-origin-ip-after-resume deny "http://$ORIGIN_IP/healthz"
run_step egress-delete-policy kubectl ate delete egress-policy "$EGRESS_ACTOR" -a "$EGRESS_ATESPACE"
date -u +%FT%T.%NZ > "$EGRESS_DIR/policy-deleted-at.txt"
kubectl ate get egress-policy "$EGRESS_ACTOR" -a "$EGRESS_ATESPACE" -o json > "$EGRESS_DIR/states/policy-after-delete.json" 2> "$EGRESS_DIR/logs/policy-after-delete.err"
probe_until hostname-after-policy-deletion deny "http://$ORIGIN_HOST/healthz"
wait_http origin-control-after http://127.0.0.1:18081/healthz
snapshot_actor final
kubectl -n ate-system get deployment atenet-egress -o json | jq '{metadata:(.metadata | {name,namespace,uid,generation}),containers:[.spec.template.spec.containers[] | {name,image}]}' > "$EGRESS_DIR/states/gateway-images.json"
printf '%s\n' 'PASS: no-policy denial, hostname allow, same-origin IP denial, synchronous suspend/resume, and policy deletion denial observed.' > "$EGRESS_DIR/result.txt"
cat "$EGRESS_DIR/result.txt"
