# Live actor lifecycle evidence

Captured on October 31, 2026 from source commit `0ddbf78d54bb6da2ccb01125b7e085aa14d555a6`. The cluster is `substrate-lifecycle`; the Kubernetes node is `substrate-lifecycle-control-plane`. All process IDs and cgroup hierarchies use that node as the host boundary. The physical machine's Docker-parent cgroup is excluded.

Read the [standalone lifecycle section](../../actor-lifecycle.md), [build provenance](build-notes.md), [network/cgroup findings](network-notes.md), and [egress test interpretation](egress-notes.md). The raw evidence contains successful observations, expected denials, and diagnostic/harness failures; an empty output must be interpreted with its corresponding exit status.

## Start with these files

| Question | Evidence |
|---|---|
| What was built and when? | [Commands](commands.tsv), [exit statuses and intervals](results.tsv), [scripts](scripts/common.sh), [build notes](build-notes.md) |
| What manifests and images actually ran? | [Applied, redacted resources](manifests/capture-20261031T180401Z), [generated kind configuration](manifests/kind-config.yaml), [final Pods](states/pods-final.txt) |
| What rules were inside the actor gateway? | [Full nftables text](selected/counter-gateway-nft.txt), [JSON with handles](selected/counter-gateway-nft.json) |
| What rules were inside the runtime and worker Pod? | [Runtime JSON](selected/counter-runtime-nft.json), [worker Pod JSON](selected/worker-pod-nft.json); both were successfully empty |
| How were the veth devices connected? | [Runtime links](selected/counter-runtime-links.json), [gateway links](selected/counter-gateway-links.json), [worker Pod links](selected/worker-pod-links.json), [node links](selected/node-links.json) |
| Which process owned gateway sockets? | [Gateway sockets](selected/counter-gateway-sockets.txt), [process and namespace explanation](network-notes.md) |
| How did cgroups connect to Kubernetes? | [Full ancestry](selected/cgroup-ancestry.tsv), [per-process/controller capture](kernel/network-counter-final-processes-20261031T175829-2068208), [hierarchy explanation](network-notes.md) |
| What happened to actor state? | [Created](states/counter-created.json), [async suspended](states/counter-suspended-async.json), [request resumed](states/counter-request-resumed.json), [sync suspended](states/counter-suspended-sync.json), [tag](states/counter-tag.json), [clone](states/counter-clone-running.json) |
| What is the real PostgreSQL schema? | [Schema-only dump](selected/postgres-schema.sql), [settings](database/final/settings.csv), [final selected rows](database/final/rows.csv) |
| How did persisted state change? | [Running protobufs](database/running/decoded-records.json), [suspended protobufs](database/suspended/decoded-records.json), [resumed protobufs](database/resumed/decoded-records.json) |
| What was stored in RustFS? | [Object keys and sizes](selected/rustfs-objects.json), [selected manifest bodies](selected/rustfs-manifests.json), [actual backend selection](selected/storage-backends.json) |
| Did egress policy survive resume? | [Probe interpretation and links](egress-notes.md), [policy input](manifests/egress-hostname-policy.json) |
| What did syscall tracing observe? | [Filtered trace](kernel/runtime-trace/syscalls.txt), [worker diagnostic log](kernel/runtime-trace/worker.log), [crashed actor record](kernel/runtime-trace/actor-after.json) |

The convenient `selected/` files are byte-for-byte copies. [Their provenance map](selected/provenance.json) identifies the original capture and SHA-256. Raw network directories include `node/status.tsv`, per-command stderr, capture time and selected Pod/CRI identities. The external router and egress Pod network namespaces are also captured in [gateway-boundaries](kernel/network-gateway-boundaries-20261031T180237-2088756).

## Results and boundaries

The original counter advanced `1/1/1` through `8/8/8` across normal operations. A durable-tag clone and the resumed original independently returned `5/5/5`. Four untraced request-driven resumes completed in 166.623–193.918 ms at the client proxy boundary. These are four observations, not a percentile or pure runsc-restore latency.

Allowed-host egress returned the unique origin body. The same origin by IP returned 403. The checks repeated across synchronous suspend/resume. Policy deletion produced DNS refusal while the origin stayed healthy. The allowed-host policy was re-created afterward; its final database row is recorded. Existing kindnet and NetworkPolicy objects do not establish Kubernetes NetworkPolicy enforcement.

A separate ptrace diagnostic disturbed sandbox startup: runsc failed, the request returned 500, and the actor became CRASHED. After detachment, an explicit revert to the completed durable snapshot and resume returned `10/10/10`. A later database comparison cycle returned `11/11/11`. The failed attempt is preserved and excluded from normal timings. The revised trace script detaches before restore; the revised ordering was syntax-checked, not rerun in this capture.

The database comparison observed actor versions 35→37→39, assignment row present→absent→present, and snapshot generation 8→9→9. RustFS captures at 18:00:36 and18:04:04 UTC preserve the corresponding generation 8 and generation 9 object prefixes. SQL scalar summaries, protobuf exports, API reads and S3 listings are separate observations, not one atomic snapshot.

## Reproduction and final state

Scripts `00`–`06` build and exercise the normal path; `capture-network.sh` and `capture-database.sh` provide staged inspection. Script 07 records the diagnostic approach, 09 performs its explicit recovery, 08 captures database lifecycle changes, and 10 records final state and restores the allowed-host policy. Read their purposes before sequencing them: scripts intentionally create named resources and are not a universally idempotent test runner. The recorded command/status files describe what actually ran.

The dedicated cluster, registry, counter, clone, egress actor, tag and HTTP origin were left available for inspection. The private kubeconfig remains on the remote machine at `/home/daman/substrate-lifecycle-evidence-20261031/kubeconfig`. It is excluded from this bundle. Set that KUBECONFIG and add the evidence `bin/` directory to PATH when using the locally built CLI. The actor proxy can be restarted with `kubectl-ate proxy actor lifecycle-counter 18000:80 -a ate-demo-counter`.

Production source files were not modified. Debugging packages were installed only inside the disposable kind node. The evidence excludes Secret objects, kubeconfig, process environments, private keys, credential values and checkpoint data payloads. Applied-object captures are redacted and cannot be replayed directly. The full e2e suite, microVM runtime, scale tests, node-loss recovery and production HA were not tested.
