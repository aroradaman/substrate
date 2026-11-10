# Appendix C. Glossary and Reading Paths

Terms here follow the v1.0.0 implementation. Capitalized resource names identify concrete API or Kubernetes types; lower-case process names identify implementations or deployment roles.

| Term | Meaning and boundary | Read next |
|---|---|---|
| Actor | Logical workload identity and lifecycle record in Substrate's API store. It can exist without an active sandbox. | Chapters 1, 5 and 6 |
| ActorAssignment | Capacity claim relating an actor to a worker, with identity/incarnation information needed by admission and recovery. | Chapter 6 |
| ActorTemplate | Immutable client-facing workload definition stored through the Substrate API. Changing an actor's template reference is different from modifying the template. | Chapters 5, 12 |
| Atespace | Substrate workload/authorization scope. It is not a Kubernetes namespace alias, even when operators use similar names. | Chapters 5, 15 |
| Worker | API record representing a worker Pod and the execution capacity it advertises. Several actors may be active on it. | Chapters 1, 6 |
| WorkerPool | Kubernetes CRD that controls a worker fleet and its sandbox-class/configuration selection. | Chapters 5, 7 |
| SandboxConfig | Cluster-scoped CRD containing runtime versions and digest-addressed assets for a sandbox class. | Chapters 5, 8, 17 |
| CSIDriverConfig | Cluster-scoped configuration connecting Substrate volume handling to a CSI implementation. | Chapters 5, 8, 12 |
| ateapi / ate-api-server | Go command and deployment role implementing the actor control plane, PostgreSQL workflows, scheduling and associated controllers. | Chapter 6 |
| atecontroller | Kubernetes infrastructure reconciliation and Pod-to-Worker synchronization process. | Chapter 7 |
| atelet | Node supervisor that prepares local state and invokes the worker protocol, with support and storage coordination services. | Chapter 8 |
| ateworker | A runtime-specific worker process implementing Run/Checkpoint/Restore/Terminate and statistics. The v1.0.0 revision has gVisor and microVM implementations. | Chapters 8, 10 and 11 |
| atenet-router | Ingress deployment role that resolves actor destinations and triggers resume, using the selected dataplane. | Chapter 14 |
| atenet-egress | Shared outbound gateway role performing identity, policy and credential handling outside actor sandboxes. | Chapters 14 and 15 |
| atunnel | Library embedded in the worker for per-actor ingress/egress transport and DNS behavior. | Chapter 14 |
| Lease | Renewable SQL ownership record used to serialize a workflow. It is not interchangeable with a row lock, assignment uniqueness, or worker epoch. | Chapter 6 |
| Worker epoch | Worker process incarnation used to reject/reconcile stale work across restarts. | Chapters 6, 8 |
| Authoritative admission | Capacity revalidation and booking inside the store transaction. Candidate selection alone is advisory. | Chapter 6 |
| Golden snapshot | Prepared starting state associated with a template's golden workflow, when configured. It is not implied for every possible cold start. | Chapters 6, 12 |
| Tag | A named retention/reference construct backed by its own copied external snapshot, with sharing and lifecycle semantics. | Chapters 5, 12, 15 |
| Fidelity | The state layers retained by a snapshot: VOLUMES, ROOTFS, or MEMORY. | Chapter 12 |
| VOLUMES | Snapshot fidelity retaining DurableDir contents, without promising process-memory continuation or all rootfs writes. | Chapter 12 |
| ROOTFS | Fidelity adding container writable-rootfs state to the durable-directory layer; processes cold-boot on restore. | Chapters 10, 11 and 12 |
| MEMORY | Fidelity adding the execution image. It carries runtime compatibility constraints beyond filesystem recovery. | Chapters 10, 11 and 12 |
| Locality | Retained node-local state that can constrain placement and avoid remote transfer. It is not itself an object-store durability guarantee. | Chapters 6, 12 |
| Durable snapshot | Completed external snapshot state tracked by the control plane, whose physical resilience depends on the configured storage backend. | Chapter 12 |
| Detach | Locality-release operation that may require upload before removing a local copy and allowing placement elsewhere. | Chapter 12 |
| Revert | Lifecycle operation returning an actor to its completed durable state while discarding current execution/local progress as defined by the workflow. | Chapters 6, 12 |
| OnDemand | Cloud Hypervisor restore mode that faults memory pages as needed. It is conditional in this revision and not the default staged CH v53 path. | Chapter 11 |
| Copy | Eager guest-memory restoration mode selected by the current version policy for affected or unknown CH versions. | Chapter 11 |
| Sentry | gVisor userspace kernel hosting the actor's application execution abstraction. It is distinct from host Linux. | Chapter 10 |
| virtiofsd | Host process serving a filesystem tree to the guest over virtio-fs. Its memory and permissions are part of the microVM boundary. | Chapter 11 |
| Runtime asset cache | Node-local immutable binary/kernel/image cache, pinned by workers and actors according to use. | Chapter 8 |
| Snapshot file cache | Cache for shared restore files. Its identity, mutability and eviction rules differ from runtime assets and OCI layers. | Chapter 12 |
| RustFS | Existing S3-compatible alternative object-store deployment in the kind manifests. Its backend credentials and failure domains remain explicit operational concerns. | Chapters 12, 16 |
| Request parking | Bounded retention/retry of requests through eligible transient resume failures, with per-actor flight sharing. | Chapter 14 |
| SPIFFE identity | URI-based workload identity carried in certificates and used by specific authentication/authorization checks. It is not by itself an authorization policy. | Chapter 15 |
| Actor JWT | Signed token asserting an actor or worker-for-actor role. Relying parties verify it through the issuer's OpenID Connect discovery document and the key set, which lists every key in the signing pool. | Chapter 15 |
| EgressPolicy | Actor-related outbound policy evaluated outside the sandbox, including permitted requests and credential effects. | Chapter 15 |
| AccessPolicy | Substrate API authorization configuration using global/atespace scopes and the embedded relation model. | Chapter 15 |
| ext_proc | Envoy's external processing protocol. The operation being delegated and trusted metadata available depend on the filter chain. | Chapters 14 and 15 |
| Preview gate | Explicit opt-in for behavior whose availability should not be inferred merely from a schema field or implementation package. | Chapters 5, 17 |
| CRI | Container Runtime Interface: the gRPC protocol the kubelet speaks over a Unix socket to containerd for sandboxes, containers and images. Actors do not use it. | Chapters 2, 3 |
| OCI bundle | A directory with `config.json` and a root filesystem, consumed by an OCI runtime such as runc or runsc. Substrate's worker writes bundles for actors itself. | Chapters 2, 9 |
| Runtime shim | Long-lived parent of a Pod's container processes, started by containerd and driving runc or runsc. Substrate's PID 1 shim plays a similar role inside the worker. | Chapters 2, 4 |
| Pause container | Minimal process that pins a Pod's shared namespaces and reaps zombies. Actors have no pause container; named namespace bind mounts pin their network namespaces. | Chapter 4 |
| CNI | Container Network Interface: plugins executed by containerd that give a Pod's network namespace an interface, IP and routes. The worker programs actor networking itself. | Chapters 4, 9 |
| Gofer | gVisor helper process that opens host files for the Sentry and serves mounts, in an identity-mapped user namespace under Substrate's flags. | Chapters 2, 10 |
| Systrap | gVisor platform that traps application system calls with seccomp `SECCOMP_RET_TRAP` in stub processes and hands them to the Sentry. | Chapters 2, 4 |
| Golden snapshot | A template's application booted once and captured, so actors created from the template restore it instead of cold-starting. | Chapters 7, 9 |

## Follow a problem through the book

**A resume is slow.** Start with Chapter 16's end-to-end measurement boundary. Use Chapter 14 to distinguish parking and proxy work, Chapter 6 for admission/lease/store contention, Chapter 12 for locality and download, and Chapter 10 or 11 for the actual restore and readiness path. A runtime phase measurement cannot explain an earlier wait for capacity.

**A worker restarts while hosting actors.** Read Chapter 8's process/registration lifecycle, then Chapter 6's epoch and assignment reconciliation. Chapter 12 explains which local and external snapshot states remain usable. The existence of a checkpoint file is not sufficient evidence that the corresponding actor record should advertise it as durable.

**Memory use grows after many restores.** Separate actor bookings from host charges using Chapter 8. Read the backend-specific cgroup and memory discussion in Chapter 10 or 11, then snapshot cache/writeback behavior in Chapter 12. Include virtiofsd, host page cache, upload buffers, and concurrent checkpoint loans before concluding that the application leaked memory.

**An actor can reach an unexpected endpoint.** Follow the network namespace and NAT path in Chapter 14, then identity/policy/DNS and TLS interception in Chapter 15. Inspect the rendered dataplane configuration and active policy cache rather than reasoning from a single base manifest. An ingress allowlist and an egress allow rule protect different traffic directions.

**A RustFS deployment is unavailable.** Chapter 12 identifies node/control plugin operations that need it and what local locality can still satisfy. Chapter 16 treats object-store recovery, bucket access, credentials, endpoints, PVC persistence and shared infrastructure failure domains. A cache hit may conceal an outage for one actor while another actor cannot resume.

**A new runtime version is introduced.** Start with Chapter 17's compatibility contract and Chapter 7's SandboxConfig selection/protection. Chapter 8 explains asset publication and worker advertisement. Chapter 6 determines compatible placement; Chapters 10, 11 and 12 determine which state can be reused or downgraded. A new worker image and a new sandbox binary are separate rollout events.
