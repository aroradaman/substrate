# Egress policy across synchronous suspend and resume

Observed on 2026-10-31, approximately 17:56:41–17:57:08 UTC, using source
`0ddbf78d54bb6da2ccb01125b7e085aa14d555a6` and the gVisor demo WorkerPool.
The kind node is the host boundary for the namespace and cgroup discussion.
These results describe one local experiment, not latency percentiles or a
production performance guarantee.

## Fixture and requests

[`scripts/06-egress.sh`](scripts/06-egress.sh) builds the repository fixture
`internal/e2e/fixtures/testserver` with `hack/run-tool.sh ko publish
--platform=linux/amd64`, then independently checks the registry digest using
`go run github.com/google/go-containerregistry/cmd/crane@latest digest
--insecure`. The deployed image was:

```text
localhost:5002/testserver-1c83b80ce58e2008bb42365908c84c50@sha256:77708dfd20b6eeb25beb64d864f0c8cfd847b138d46cc7b18fc508b17a2ee631
```

The origin Deployment runs `http --listen=:8080
--body=substrate-lifecycle-origin-20261031`. Its Service maps port 80 to
8080 and had ClusterIP `10.96.249.148`. The name
`origin.lifecycle-target.svc.cluster.local` addresses this same Service.
A separate port-forward verified its `/healthz` before and after the policy
experiment. See [origin manifest](manifests/egress-origin.yaml),
[registry verification](egress/origin-verified-digest.txt), and
[Service state](egress/states/origin-service.json).

The actor was `lifecycle-egress` in `ate-demo-egress`, UID
`8fe5de26-cc8a-40e4-aa86-770a6bd8c43e`. A `kubectl ate proxy actor`
process exposed its port 80 on local port 18080. Each request posted the
following shape to the demo actor:

```json
{"url":"http://origin.lifecycle-target.svc.cluster.local/healthz","http1":true}
```

The demo's `http1` option creates a new upstream transport and closes its idle
connections. This reduces connection reuse as an explanation for policy
results. All request bodies, response bodies, HTTP headers, curl exit codes,
and timings are under [egress](egress/). The exact hostname policy allows only
HTTP port 80; see [policy JSON](manifests/egress-hostname-policy.json).

## Observed outcomes

| Stage | Observed result | Client request time | Evidence |
|---|---|---:|---|
| No policy; origin requested by ClusterIP | 502, connection reset; gateway logged `egress denied: actor has no egress policy` | 48.288 ms | [Response](egress/responses/no-policy-final.json), [gateway log](egress/logs/gateway-ext-proc.log) |
| Hostname policy created; origin requested by hostname | First 18 probes returned 502; probe 19 returned 200 with the unique fixture body | Successful request: 49.972 ms | [Response](egress/responses/hostname-allowed-final.json), [all probes](egress/probes.tsv) |
| Same origin requested by ClusterIP | 403 with `egress denied`; gateway logged the numeric host, port 80, and no matching rule | 38.246 ms | [Response](egress/responses/same-origin-ip-denied-final.json) |
| `suspend actor --mode=sync` | Actor became `ACTOR_STATE_SUSPENDED`; generation 2 MEMORY snapshot had durable state COMPLETED | CLI wall time: 0.27 s | [State](egress/states/actor-suspended.json), [time output](metrics/egress-sync-suspend.time.txt) |
| First hostname request after suspend | 200 with the same fixture body; actor became RUNNING | 178.538 ms | [Response](egress/responses/hostname-after-resume-final.json), [state](egress/states/actor-resumed.json) |
| ClusterIP request after resume | 403 with `egress denied` | 38.473 ms | [Response](egress/responses/same-origin-ip-after-resume-final.json) |
| Policy deleted; hostname requested again | First probe returned 502 with DNS `no such host` from `169.254.17.1:53` | 37.335 ms | [Response](egress/responses/hostname-after-policy-deletion-final.json) |

The successful hostname request completed approximately 10.132 seconds after
the policy's API `createTime`. The first post-create probe and the successful
probe began 9.971 seconds apart. The gateway continued logging “actor has no
egress policy” during that interval. This is consistent with the ten-second
negative policy cache in
[`policycache.go`](../../../cmd/atenet/internal/router/egress/policycache.go),
which also caches missing policies. The polling loop checked the actual
response every time; it did not assume that a fixed sleep would make the
policy active.

The deletion timestamp was `2026-10-31T17:57:07.465906663Z`, recorded after the
delete command returned. The next probe began about 105 ms later and completed
about 143 ms after that timestamp. Its DNS refusal shows that the hostname
request was stopped before reaching the origin. It does **not** measure
ext_proc cache invalidation or establish instantaneous revocation for existing
connections. The origin still passed the independent health check.

## Snapshot and worker evidence

Actor creation borrowed generation 1 from the template's durable golden tag
`11c4465b-dd9c-4b29-ad27-6ade7a0a994a`. The first activation therefore exercised
restore from the golden snapshot. It was not a cold image start.

Synchronous suspend produced actor-owned generation 2, UUID
`7a91badb-26b4-437b-915b-3d2ada473b50`, with node locality
`substrate-lifecycle-control-plane` and a completed durable snapshot. The
suspended API record had no `workerAssignment`. The resumed record assigned
the same worker Pod `egress-78cb8c86b6-l8b67`, UID
`046447c4-3c24-4c3f-8632-9d639a266bde`, at `10.244.0.26`, epoch 1.

This test establishes policy behavior before and after a real MEMORY
checkpoint/restore. The egress demo's response has no persistent application
counter, so it does not independently establish application-memory continuity;
the counter experiment supplies that evidence. The 178.538 ms measurement
includes the local proxy, ingress routing, activation, actor handling, egress,
and origin response. It is not an isolated `runsc restore` duration.

Network evidence was captured at these stages:

```text
kernel/network-egress-running-20261031T175653-2045814
kernel/network-egress-resumed-20261031T175700-2057329
```

Those captures record namespaces, links, routes, nftables, sockets, and
process/cgroup ancestry. Packet tracing was disabled for these captures, so
the topology snapshots alone do not prove a particular packet traversed every
hop. The successful origin response and gateway policy logs provide the
request-level evidence.

## Harness correction and validation

The initial attempt stopped after creating its actor because the harness
expected a list envelope from `get actor NAME -o json`; this command returns a
single Actor object. No egress probes ran in that attempt. Its state and logs
were preserved under [egress-initial-harness-failure](egress-initial-harness-failure/),
that test actor was deleted, and the corrected script created the actor used
above. An initial SSH wrapper also used zsh's read-only `status` variable;
subsequent execution used Bash. Neither failure indicates a Substrate fault.

The corrected run exited zero and recorded
[its result](egress/result.txt). The script passes `bash -n` and
`shellcheck -x`. It leaves the final actor and origin in place, with the
actor's egress policy deleted; it closes its own port-forward processes.

The automated denial predicate follows the repository's egress test helper:
it accepts an explicit 403 denial or a 502 containing `request failed`.
A generic upstream failure can also produce that 502, so the script's PASS
line alone is insufficient evidence of policy enforcement. This run's
no-policy result is corroborated by the actor-specific gateway denial log;
the deletion result is the specific DNS refusal, with the origin still
healthy. An independent agent reviewed the script and these interpretations.
