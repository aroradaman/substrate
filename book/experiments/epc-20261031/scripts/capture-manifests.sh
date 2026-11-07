#!/usr/bin/env bash
# Capture selected live objects and provenance without exporting credentials.
set -euo pipefail
umask 077

TASK_SOURCE=${TASK_SOURCE:-/home/daman/substrate-lifecycle-20261031}
TASK_EVIDENCE=${TASK_EVIDENCE:-/home/daman/substrate-lifecycle-evidence-20261031}
TASK_REVISION=0ddbf78d54bb6da2ccb01125b7e085aa14d555a6
export PATH="$TASK_EVIDENCE/bin:/usr/local/go/bin:/home/daman/go/bin:$PATH"
export KUBECONFIG="$TASK_EVIDENCE/kubeconfig"
TASK_CONTEXT=kind-substrate-lifecycle
TASK_CAPTURE="$TASK_EVIDENCE/manifests/capture-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$TASK_CAPTURE"/{applied,provenance}
cd "$TASK_SOURCE"
[[ $(git rev-parse HEAD) == "$TASK_REVISION" ]] || { echo 'Unexpected source revision' >&2; exit 1; }
for tool in kubectl jq python3 git; do
  command -v "$tool" >/dev/null || { printf 'Missing tool: %s\n' "$tool" >&2; exit 1; }
done
KUBE=(kubectl --context="$TASK_CONTEXT" --request-timeout=30s)

# Discard status and arbitrary text-bearing fields. Keep references and topology.
# Raw API responses are piped into jq and are never written to an output file.
SANITIZE='
  def scrub:
    walk(if type == "object" then
      if (.metadata | type) == "object" then .metadata |= del(.managedFields, .annotations) else . end
      | if (.command | type) == "array" then .command = ["<redacted>"] else . end
      | if (.args | type) == "array" then .args = ["<redacted>"] else . end
      | if (.env | type) == "array" then .env |= map(if has("value") then .value = "<redacted>" else . end) else . end
      | if (.httpHeaders | type) == "array" then .httpHeaders |= map(.value = "<redacted>") else . end
      | if (.url | type) == "string" then .url = "<redacted>" else . end
      else . end);
  .items |= map(select(.kind != "Secret") | del(.status)
    | if .kind == "ConfigMap" then
        .data = ((.data // {}) | map_values("<redacted>"))
        | .binaryData = ((.binaryData // {}) | map_values("<redacted>"))
      else . end | scrub)
  | del(.metadata)
'

capture() {
  local name=$1
  shift
  local output="$TASK_CAPTURE/applied/$name.json"
  if "${KUBE[@]}" get "$@" -o json | jq -S "$SANITIZE" > "$output.partial"; then
    mv "$output.partial" "$output"
  else
    rm -f "$output.partial"
    printf 'Capture failed: %s\n' "$name" >&2
    return 1
  fi
}

namespaces=(ate-system podcertificate-controller-system ate-demo-counter ate-demo-egress)
for ns in "${namespaces[@]}"; do
  # An empty list is valid when a demo has not yet been deployed.
  capture "$ns-workloads" deployments.apps,daemonsets.apps,statefulsets.apps,replicasets.apps,pods,jobs.batch -n "$ns"
  capture "$ns-network-config" services,networkpolicies.networking.k8s.io,serviceaccounts,configmaps,roles.rbac.authorization.k8s.io,rolebindings.rbac.authorization.k8s.io,persistentvolumeclaims -n "$ns"
  capture "$ns-workerpools" workerpools.ate.dev -n "$ns"
  "${KUBE[@]}" get pods -n "$ns" -o json | jq -S '
    [.items[] | {namespace:.metadata.namespace, name:.metadata.name, uid:.metadata.uid,
      node:.spec.nodeName, phase:.status.phase,
      containers:([.status.initContainerStatuses[]?,.status.containerStatuses[]?]
        | map({name,image,imageID,ready,restartCount,
               waitingReason:.state.waiting.reason, terminatedReason:.state.terminated.reason,
               exitCode:.state.terminated.exitCode}))}]
  ' > "$TASK_CAPTURE/provenance/$ns-pod-images.json"
done
capture sandboxconfigs sandboxconfigs.ate.dev
capture csidriverconfigs csidriverconfigs.ate.dev
"${KUBE[@]}" get customresourcedefinitions.apiextensions.k8s.io -o json |
  jq '.items |= map(select(.spec.group == "ate.dev"))' |
  jq -S "$SANITIZE" > "$TASK_CAPTURE/applied/ate-crds.json"
"${KUBE[@]}" get validatingadmissionpolicies.admissionregistration.k8s.io,validatingadmissionpolicybindings.admissionregistration.k8s.io,clusterroles.rbac.authorization.k8s.io,clusterrolebindings.rbac.authorization.k8s.io -o json |
  jq '.items |= map(select(.metadata.name | test("ate|podcert|sandboxconfig")))' |
  jq -S "$SANITIZE" > "$TASK_CAPTURE/applied/cluster-policy-rbac.json"
"${KUBE[@]}" get nodes -o json | jq -S '
  [.items[] | {name:.metadata.name, uid:.metadata.uid,
    architecture:.status.nodeInfo.architecture, osImage:.status.nodeInfo.osImage,
    kernelVersion:.status.nodeInfo.kernelVersion, kubeletVersion:.status.nodeInfo.kubeletVersion,
    containerRuntimeVersion:.status.nodeInfo.containerRuntimeVersion,
    capacity:.status.capacity, allocatable:.status.allocatable}]
' > "$TASK_CAPTURE/provenance/nodes.json"
"${KUBE[@]}" version -o json > "$TASK_CAPTURE/provenance/kubernetes-version.json"

# Hash only tracked installer/build inputs. Do not read private record files,
# kubeconfig, Docker config, generated credentials, or arbitrary environment.
python3 - "$TASK_SOURCE" "$TASK_CAPTURE/provenance/source-inputs.json" <<'PY'
import hashlib, json, pathlib, subprocess, sys
root = pathlib.Path(sys.argv[1])
paths = subprocess.check_output([
    "git", "ls-files", "-z", "--", ".ko.yaml", "go.mod", "go.sum",
    "manifests", "cmd/ate-setup", "cmd/dataplane/envoy", "hack/tools/ko",
    "hack/tools/kind", "hack/kind.sh", "hack/create-kind-cluster.sh",
    "demos/counter", "demos/egress"], cwd=root).split(b"\0")
records = []
for raw in paths:
    if not raw:
        continue
    rel = raw.decode()
    path = root / rel
    if path.is_symlink():
        records.append({"path": rel, "symlink": str(path.readlink())})
    elif path.is_file():
        data = path.read_bytes()
        records.append({"path": rel, "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()})
pathlib.Path(sys.argv[2]).write_text(json.dumps(records, indent=2) + "\n")
PY
{
  date -u +%FT%TZ
  git show -s --format='revision=%H%ncommit_time=%cI' HEAD
  printf 'effective_go='; go version
  printf 'launcher_go_without_auto_selection='; GOTOOLCHAIN=local /usr/local/go/bin/go version
  printf 'docker='; docker version --format '{{.Client.Version}} / {{.Server.Version}}'
  docker buildx version
  jq --version
  python3 --version
  if command -v kind >/dev/null; then printf 'ambient_kind='; kind version; fi
  if [[ -f "$TASK_EVIDENCE/logs/resolve-kind.log" ]]; then
    awk '/^kind v/ {print "pinned_kind_wrapper_record=" $0}' "$TASK_EVIDENCE/logs/resolve-kind.log"
  fi
  if command -v ko >/dev/null; then printf 'ambient_ko='; ko version; fi
} > "$TASK_CAPTURE/provenance/tool-versions.txt"
for binary in ate-setup kubectl-ate; do
  if [[ -f "$TASK_EVIDENCE/bin/$binary" ]]; then
    go version -m "$TASK_EVIDENCE/bin/$binary" > "$TASK_CAPTURE/provenance/$binary-build-info.txt"
  fi
done
cat > "$TASK_CAPTURE/README.txt" <<'TEXT'
These are selected live Kubernetes objects observed after API admission,
defaulting and controller reconciliation. They are NOT the exact bytes passed
by ate-setup to server-side apply and are NOT a replayable installation bundle.
Secret objects and private credential files were not requested. ConfigMap
values, literal environment values, command/argument arrays, HTTP header
values, URL fields, annotations, managedFields, status and free-form messages
were removed or redacted. Pod image/status summaries contain selected fields.
Resource names, Secret references, image references and topology remain.
source-inputs.json hashes tracked source inputs; it does not export their
contents. Missing demo resources mean only that they were absent at capture.
Capture is sequential, not an atomic snapshot across Kubernetes resources.
TEXT
# Explicit opt-in: list snapshot object metadata from the deployed RustFS.
# Read existing job credentials only in memory; publish bucket/key/size only.
if [[ ${TASK_LIST_RUSTFS:-0} == 1 ]]; then
  python3 - "$TASK_CAPTURE" "$TASK_CONTEXT" <<'PY_RUSTFS'
import datetime, hashlib, hmac, json, pathlib, re, selectors, subprocess, sys
import urllib.error, urllib.parse, urllib.request, xml.etree.ElementTree as ET

out = pathlib.Path(sys.argv[1]) / "provenance"
kube = ["kubectl", "--context=" + sys.argv[2], "--request-timeout=30s"]
def get(*args):
    return json.loads(subprocess.check_output(kube + ["get", *args, "-o", "json"]))
pods = get("pods", "-n", "ate-system")
safe = []
for pod in pods["items"]:
    for container in pod["spec"].get("initContainers", []) + pod["spec"]["containers"]:
        env = {v["name"]: v["value"] for v in container.get("env", []) if "value" in v}
        if "ATE_STORAGE_BACKEND" in env:
            safe.append({"pod": pod["metadata"]["name"], "container": container["name"],
                         "ATE_STORAGE_BACKEND": env["ATE_STORAGE_BACKEND"],
                         "AWS_ENDPOINT_URL": env.get("AWS_ENDPOINT_URL")})
assert safe and all(v["ATE_STORAGE_BACKEND"] == "s3" and
    v["AWS_ENDPOINT_URL"] == "http://rustfs.ate-system.svc:9000" for v in safe)
(out / "deployed-storage-backends.json").write_text(json.dumps(safe, indent=2) + "\n")
job = get("job", "rustfs-bucket-init", "-n", "ate-system")
private = {v["name"]: v["value"] for v in
           job["spec"]["template"]["spec"]["containers"][0]["env"] if "value" in v}
assert private["AWS_ENDPOINT_URL"] == "http://rustfs.ate-system.svc:9000"
access, secret = private["AWS_ACCESS_KEY_ID"], private["AWS_SECRET_ACCESS_KEY"]
region = private.get("AWS_REGION", "us-east-1")
forward = subprocess.Popen(kube + ["port-forward", "--address=127.0.0.1", "-n",
    "ate-system", "service/rustfs", ":9000"], stdout=subprocess.PIPE,
    stderr=subprocess.DEVNULL, text=True)
try:
    selector = selectors.DefaultSelector()
    selector.register(forward.stdout, selectors.EVENT_READ)
    if not selector.select(timeout=30):
        raise RuntimeError("RustFS port-forward did not become ready")
    line = forward.stdout.readline()
    match = re.search(r"127\.0\.0\.1:(\d+)", line)
    if not match:
        raise RuntimeError("RustFS port-forward did not report a loopback port")
    host = "127.0.0.1:" + match.group(1)
    bucket, objects, token = "ate-snapshots", [], None
    namespace = {"s3": "http://s3.amazonaws.com/doc/2006-03-01/"}
    def request_bytes(path, query, max_bytes):
        now = datetime.datetime.now(datetime.timezone.utc)
        timestamp, day = now.strftime("%Y%m%dT%H%M%SZ"), now.strftime("%Y%m%d")
        encoded = urllib.parse.urlencode(sorted(query.items()), quote_via=urllib.parse.quote)
        encoded_path = urllib.parse.quote(path, safe="/~")
        payload = hashlib.sha256(b"").hexdigest()
        headers = {"host": host, "x-amz-content-sha256": payload, "x-amz-date": timestamp}
        signed = ";".join(sorted(headers))
        canonical_headers = "".join(key + ":" + headers[key] + "\n" for key in sorted(headers))
        canonical = "\n".join(["GET", encoded_path, encoded, canonical_headers, signed, payload])
        scope = day + "/" + region + "/s3/aws4_request"
        to_sign = "\n".join(["AWS4-HMAC-SHA256", timestamp, scope,
                             hashlib.sha256(canonical.encode()).hexdigest()])
        key = ("AWS4" + secret).encode()
        for value in [day, region, "s3", "aws4_request"]:
            key = hmac.new(key, value.encode(), hashlib.sha256).digest()
        signature = hmac.new(key, to_sign.encode(), hashlib.sha256).hexdigest()
        headers["Authorization"] = ("AWS4-HMAC-SHA256 Credential=" + access + "/" + scope +
            ", SignedHeaders=" + signed + ", Signature=" + signature)
        request = urllib.request.Request("http://" + host + encoded_path +
            ("?" + encoded if encoded else ""), headers=headers)
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                body = response.read(max_bytes + 1)
        except urllib.error.HTTPError as error:
            raise RuntimeError("RustFS read returned HTTP " + str(error.code)) from None
        if len(body) > max_bytes:
            raise RuntimeError("RustFS metadata exceeds capture size limit")
        return body
    while True:
        query = {"list-type": "2", "max-keys": "1000"}
        if token:
            query["continuation-token"] = token
        page = ET.fromstring(request_bytes("/" + bucket, query, 4 * 1024 * 1024))
        for item in page.findall("s3:Contents", namespace):
            objects.append({"bucket": bucket, "key": item.findtext("s3:Key", namespaces=namespace),
                            "size": int(item.findtext("s3:Size", namespaces=namespace))})
        if page.findtext("s3:IsTruncated", namespaces=namespace) != "true":
            break
        token = page.findtext("s3:NextContinuationToken", namespaces=namespace)
        if not token:
            raise RuntimeError("Truncated RustFS listing has no continuation token")
    (out / "rustfs-objects.json").write_text(json.dumps({
        "captured_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "service": "ate-system/rustfs", "operation": "ListObjectsV2",
        "objects": sorted(objects, key=lambda obj: obj["key"])}, indent=2) + "\n")
    manifests = []
    allowed = ("sandboxClass", "atespace", "actorName", "actorUid",
               "actorTemplateAtespace", "actorTemplateName", "snapshotFiles",
               "dataSnapshotFiles", "fidelity")
    for obj in objects:
        if not obj["key"].endswith("/manifest.json"):
            continue
        body = json.loads(request_bytes("/" + bucket + "/" + obj["key"], {}, 1024 * 1024))
        selected = {key: body[key] for key in allowed if key in body}
        selected["assets"] = {name: {"sha256": asset.get("sha256")} for name, asset in
                              body.get("assets", {}).items()}
        manifests.append({"bucket": bucket, "key": obj["key"], "selected_fields": selected})
    (out / "rustfs-manifests.json").write_text(json.dumps(manifests, indent=2) + "\n")
    print("RustFS object metadata captured: " + str(len(objects)))
    print("Selected snapshot manifest fields captured: " + str(len(manifests)))
finally:
    forward.terminate()
    try:
        forward.wait(timeout=5)
    except subprocess.TimeoutExpired:
        forward.kill()
        forward.wait()
PY_RUSTFS
fi
printf '%s\n' "$TASK_CAPTURE"
