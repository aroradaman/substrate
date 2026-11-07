# Appendix B. Source Inventory and Implementation Status

The inventory is anchored to commit `0ddbf78d54bb6da2ccb01125b7e085aa14d555a6`. It records source ownership, not a deployment inventory collected from a running cluster. Counts were taken before creating `book/`, excluding Git's object database.

## Whole-clone coverage

| Area | Files | Architectural relevance |
|---|---:|---|
| `api/` | 22 | Public gRPC definitions, generated bindings, and infrastructure CRD types. |
| `cmd/` | 777 | Daemons, runtime workers, installer, CLI, plugin implementations, Rust Envoy modules, and benchmark binaries. |
| `internal/` | 559 | Shared runtime/network/storage/identity machinery, internal protocols, test fixtures, and end-to-end suites. |
| `pkg/` | 73 | Public helper packages, CRD clients, asset fetching, object storage, and configuration protocol. |
| `manifests/` | 47 | Deployment, identity, policy, storage, generated CRDs, and alternate dataplane wiring. |
| `docs/` | 58 | Architecture, resource and API contracts, security, operations, metrics, and development guidance. |
| `benchmarking/` | 167 | Load generation, open-loop tunnel tests, isolated-component tests, orchestration, and analysis. |
| `demos/` | 46 | Counter, sandbox, Jupyter, parking, egress, multiple templates, and coding-agent workloads. |
| `hack/` | 96 | Generation, validation, privileged tests, kind setup, and copied CSI deployment examples. |
| `tools/` | 72 | API linting, JUnit verification, cloud provisioning, documentation generation, and image-cache validation. |
| `site/` | 82 | Hugo/Docsy documentation presentation and tests; not a runtime management UI. |
| `.github/` | 11 | CI, release, vulnerability checks, and documentation publication workflows. |
| `vendor/` | 11,794 | Dependency source and generated bindings; relevant syscall/protocol wrappers were traced from integration points. |
| `_LICENSES/` | 300 | Attribution and dependency licensing material. |
| `logo/`, `.agents/`, `.idea/`, root files | 41 | Branding, contributor tooling, local IDE metadata, module/configuration and governance files. |
| **Total** | **14,145** | The inventory crosses every top-level directory; detailed analysis follows execution relevance. |

The module name is `go.ate.dev/substrate`. The main [go.mod](../go.mod) pins Go and library dependencies. Independent tools have their own modules. [`.ko.yaml`](../.ko.yaml) records base images and Linux build architectures. Runtime assets are separately selected by SandboxConfig; they are not implied by the main Go module dependency graph.

## Component ownership

| Component or subsystem | Source entry points | State and responsibility |
|---|---|---|
| API process | [cmd/ateapi/main.go](../cmd/ateapi/main.go), [controlapi](../cmd/ateapi/internal/controlapi) | Registers Control and WorkerService, wires authorization/store/scheduler, and hosts actor workflows and internal reconcilers. |
| Placement | [scheduling.go](../cmd/ateapi/internal/scheduling/scheduling.go), [worker_assignment.go](../cmd/ateapi/internal/store/atepg/worker_assignment.go) | Selects compatible candidates and revalidates bookings transactionally. Candidate preference is not an exclusive reservation. |
| PostgreSQL consistency | [lease.go](../cmd/ateapi/internal/store/atepg/lease.go), [outbox.go](../cmd/ateapi/internal/store/atepg/outbox.go), [migrations](../cmd/ateapi/internal/store/atepg/migrations) | Renewable leases, object writes, unique assignments, worker events, and schema evolution. |
| Kubernetes controllers | [cmd/atecontroller/main.go](../cmd/atecontroller/main.go), [controllers](../cmd/atecontroller/internal/controllers) | WorkerPool Deployments, SandboxConfig protection, per-pool NetworkPolicy, and egress trust distribution. |
| Worker registry synchronization | [workersync/syncer.go](../cmd/atecontroller/internal/workersync/syncer.go) | Independent informer/workqueue path connecting Pods to API Worker records. |
| Golden snapshot and epoch recovery | [template_reconciler.go](../cmd/ateapi/internal/controlapi/template_reconciler.go), [worker_assignment_reconciler.go](../cmd/ateapi/internal/controlapi/worker_assignment_reconciler.go) | Background work inside ateapi; not controller-runtime reconcilers in atecontroller. |
| Node supervisor | [cmd/atelet/main.go](../cmd/atelet/main.go), [workersupport.go](../cmd/atelet/workersupport.go) | Prepares actor state and bundles, invokes workers, brokers support requests, coordinates local snapshot state. |
| gVisor worker | [main.go](../cmd/ateworker-gvisor/main.go), [runsc.go](../cmd/ateworker-gvisor/runsc.go), [hosted.go](../cmd/ateworker-gvisor/hosted.go) | Actor admission and Sentry lifecycle, checkpoint/restore commands, resource enforcement and cleanup. |
| MicroVM worker | [run.go](../cmd/ateworker-microvm/run.go), [restore.go](../cmd/ateworker-microvm/restore.go), [internal/ch](../cmd/ateworker-microvm/internal/ch), [internal/kata](../cmd/ateworker-microvm/internal/kata) | VMM/virtiofsd/guest-agent lifecycle, host overlays, TAP, VM snapshots, restore repair. |
| Shared worker implementation | [internal/ateworker](../internal/ateworker), [internal/ocispec](../internal/ocispec), [internal/hardware](../internal/hardware) | Registration, actor network, cgroups, memory borrowing, PID1 behavior, workload shaping and compatibility data. |
| Node caches | [internal/imagecache](../internal/imagecache), [filecache](../cmd/atelet/internal/filecache), [snapshottracker](../cmd/atelet/internal/snapshottracker) | Image layers, immutable assets/shared snapshot files, local checkpoint/upload/detach bookkeeping. Their eviction rules and ownership differ. |
| Object-store plugin | [cmd/objectstore-plugin](../cmd/objectstore-plugin), [internal/objectstoreplugin](../internal/objectstoreplugin), [pkg/objectstorage](../pkg/objectstorage) | Node transfer/asset services and control-side copy/delete; GCS or S3 clients and bounded upload buffering. |
| RustFS alternative | [kind/rustfs.yaml](../manifests/ate-install/kind/rustfs.yaml), [node overlay](../manifests/ate-install/kind/atelet/kustomization.yaml), [control overlay](../manifests/ate-install/kind/ate-api-server/kustomization.yaml) | In-cluster S3-compatible backend, bucket initialization, API access policy, matching endpoints and path-style addressing on both plugin sides. |
| Network control/proxy | [cmd/atenet](../cmd/atenet), [router](../cmd/atenet/internal/router), [sdsmint](../cmd/atenet/internal/sdsmint) | Shared binary for routing/external processing and certificate minting; separate ingress/egress deployment roles. |
| Worker transport | [internal/atunnel](../internal/atunnel), [internal/netns](../internal/netns) | Embedded ingress/egress tunnel, per-activation transport lifetime and policy-aware DNS. |
| Envoy extension | [Rust dynamic module](../cmd/dataplane/envoy/dynamic-modules/egress-policy/src), [Envoy Dockerfile](../cmd/dataplane/envoy/Dockerfile) | Policy ownership/filter-state behavior implemented outside Go. |
| Alternate dataplane | [AgentGateway component](../manifests/ate-install/components/agentgateway), [static mTLS component](../manifests/ate-install/components/agentgateway-static-mtls) | Native Substrate ingress integration; installer composition establishes the secured listener configuration. |
| Identity and authorization | [podcertcontroller](../cmd/podcertcontroller), [ate-idp-server](../cmd/ate-idp-server), [authz](../cmd/ateapi/internal/authz), [oidcjwt](../internal/oidcjwt) | Component certificates, actor JWT key discovery, API authentication/authorization and token validation. |
| Credential provider | [Kubernetes Secrets provider](../cmd/credential-provider/kubernetes-secrets), [credential API](../api/credprovider/v1/credprovider.proto) | Out-of-sandbox secret lookup with atespace-to-namespace authorization. |
| Operations | [kubectl-ate](../cmd/kubectl-ate), [ate-setup](../cmd/ate-setup), [serverboot](../internal/serverboot), [metrics registry](../docs/metrics/registry) | Human/API access, installation, telemetry plumbing, signal definitions and operational configuration. |

## Protocol map

| Contract | Definition | Consumers |
|---|---|---|
| Actor and control API | [api/ateapi/v1/ateapi.proto](../api/ateapi/v1/ateapi.proto) | CLI, routers, controller, node supervisor, API server; Control and WorkerService. |
| Kubernetes infrastructure API | [api/infra/k8s/ate/v1](../api/infra/k8s/ate/v1) | kube-apiserver, controllers, supervisor, generated clientset/listers/informers. |
| WorkerSupport and Atelet | [internal/proto/ateletpb/atelet.proto](../internal/proto/ateletpb/atelet.proto) | Worker-to-node support and API-to-node execution coordination. |
| Worker execution API | [internal/proto/ateworkerpb/ateworker.proto](../internal/proto/ateworkerpb/ateworker.proto) | Node supervisor and both worker backends. |
| Object storage plugin | [api/objectstore/v1/objectstore.proto](../api/objectstore/v1/objectstore.proto) | NodeProvider, ControlProvider, AssetProvider over local plugin sockets. |
| Credential provider | [api/credprovider/v1/credprovider.proto](../api/credprovider/v1/credprovider.proto) | Egress gateway and credential backend. |
| GCS transfer exchange | [internal/proto/objectstoreexchangepb/exchange.proto](../internal/proto/objectstoreexchangepb/exchange.proto) | In-tree node/control sidecars; a private provider exchange, not a universal external credential protocol. |
| Kata agent messages | [vendored Kata protocol provenance](../cmd/ateworker-microvm/internal/third_party/kata/PROVENANCE.md) | MicroVM worker's ttrpc client to guest kata-agent. |
| Configuration | [pkg/proto/ateconfigpb/apiconfig.proto](../pkg/proto/ateconfigpb/apiconfig.proto) | API configuration, including authentication settings. |
| Benchmark guest API | [internal/proto/ateenv/v1alpha/guest.proto](../internal/proto/ateenv/v1alpha/guest.proto) | Benchmark integration copy; not the core sandbox worker contract. |

`pkg/client` is the generated Kubernetes infrastructure client. The actor API client comes from the generated bindings next to `api/ateapi/v1/ateapi.proto`. Confusing the two leads to incorrect assumptions about watches, resource versions, authentication, and persistence.

## Implementation, target, and unfinished work

| Topic | Baseline status | Evidence and interpretation |
|---|---|---|
| Multiple active actors per worker | Implemented | Scheduler bookings and both runtime admission paths account for slots, CPU and memory. |
| Automatic idle suspension | Not wired into production workers | [suspend requester](../internal/ateworker/suspend/suspend.go) and upward RPCs exist, but no production runtime constructs the requester; [parking demo](../demos/parking/load.sh) explicitly describes the missing automation. |
| Activation latency | Target, not demonstrated by this audit | [architecture](../docs/concepts/architecture.md) sets 100ms at p95. Runtime timings alone omit storage, admission, routing, and probes. |
| Billion actors and 1,000 wakeups/s | North-star targets | The same architecture document names them; they are not acceptance-test results in this manuscript. |
| MicroVM demand paging | Implemented conditionally, not the default staged behavior | [prefault policy](../cmd/ateworker-microvm/internal/ch/prefault.go), [restore selection](../cmd/ateworker-microvm/restore.go), and [asset pins](../cmd/ate-setup/internal/steps/microvm.go) lead to Copy for the default CH v53.0. |
| Incremental snapshot mechanics | Partial implementation | [sparse merge](../cmd/ateworker-microvm/internal/ch/merge.go) completes OnDemand deltas. It does not implement remote incremental snapshot chains. |
| Tiered state storage | Concrete local/durable paths; no general page-tiering contract | [snapshot tracker](../cmd/atelet/internal/snapshottracker) and caches distinguish node-local files and object storage. Host page cache is another resource domain, not proof of a policy-controlled RAM/SSD/object-page hierarchy. |
| Runtime-aware restore and fidelity fallback | Implemented | Scheduler/runtime metadata and resume workflows preserve sandbox class while selecting compatible memory restore or a permitted lower fidelity. |
| Actor-to-actor authorization | Future | [security status](../docs/security/security.md) marks it future; default lateral network access is blocked. |
| Per-actor ingress authorization | Absent | Static SPIFFE client allowlisting does not grant only selected actor targets. |
| External volumes | Preview | [preview gates](../internal/preview/preview.go) gate CSI-backed external volumes. Actor cloning with those volumes is constrained by missing CSI snapshot integration. |
| Per-template storage locations and golden egress policy | Preview | Both are explicit gates in the same source. |
| GCS actor-scoped transfer credentials | Implemented | [objectstore-plugin README](../cmd/objectstore-plugin/README.md) and exchange implementation scope transfers by actor. |
| S3/RustFS actor-scoped transfer credentials | Not implemented in the in-tree S3 path | S3 uses the plugin's configured ambient credentials; supporting S3 does not imply parity with GCS credential exchange. |
| Egress additional ext_proc | Experimental, headers-only | [extensibility guide](../docs/security/extensibility.md) describes the current hook after built-in checks. |
| Ingress augmentation/replacement | Documented future work | The same guide names planned work; existing alternate AgentGateway wiring should be discussed separately. |
| Stable version-skew contract | Applies from 1.0 | [version-skew policy](../docs/reference/version-skew-policy.md) defines the future contract; current pre-1.0 guidance does not promise backward compatibility. |
| Actor-level telemetry correlation | Incomplete | [observability guide](../docs/guides/observability.md) and [metrics gaps](../docs/metrics/substrate.yaml) enumerate missing attribution and instrumentation. |

## Evidence from tests and benchmarks

The repository's CI runs ordinary/race tests, Rust-module checks, privileged Linux tests, and a runtime/dataplane/preview matrix. AgentGateway's lane has different gating semantics from the principal lane. [The workflow](../.github/workflows/pr-workflow.yaml) is evidence of intended validation coverage, not evidence that this checkout passed that coverage while the book was written.

The [tunnel harness](../benchmarking/atunnel/README.md) exercises real atunnel and namespace behavior while replacing other components. The [Nighthawk ingress harness](../benchmarking/nighthawk-ingress/README.md) uses an adaptive mean-plus-two-standard-deviations criterion that must not be relabeled as p95. [Phase analysis](../benchmarking/analysis/phase_report.py) joins node and runtime records; overlapping phases cannot simply be added. These distinctions determine which production claims a measurement can support.

## Runtime provenance

The baseline gVisor [SandboxConfig](../manifests/ate-install/sandboxconfig-gvisor.yaml) pins release `20261026.0` with per-architecture digests. The installer [microVM asset code](../cmd/ate-setup/internal/steps/microvm.go) defaults to Kata `4.3.1` and Cloud Hypervisor `v53.0`. The copied Kata message definitions document their own upstream provenance and compatibility check; they are not a vendored full Kata runtime.

RustFS is pinned to `1.0.3` by digest in the local manifest. The exact storage semantics relevant to Substrate include object writes, reads and ranges, prefix copy/delete, multipart behavior, error handling, and restart persistence. A successful bucket creation proves only one small part of that contract. The book treats the repository integration as evidence of the chosen backend path and calls for workload-specific validation before assigning a production durability objective to it.
