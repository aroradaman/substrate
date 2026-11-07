# Appendix C. Glossary and Reading Paths

Terms here follow the implementation baseline. Capitalized resource names identify concrete API or Kubernetes types; lower-case process names identify implementations or deployment roles.

| Term | Meaning and boundary | Read next |
|---|---|---|
| Actor | Logical workload identity and lifecycle record in Substrate's API store. It can exist without an active sandbox. | Chapters 1–3 |
| ActorAssignment | Capacity claim relating an actor to a worker, with identity/incarnation information needed by admission and recovery. | Chapter 3 |
| ActorTemplate | Immutable client-facing workload definition stored through the Substrate API. Changing an actor's template reference is different from modifying the template. | Chapters 2, 8 |
| Atespace | Substrate workload/authorization scope. It is not a Kubernetes namespace alias, even when operators use similar names. | Chapters 2, 10 |
| Worker | API record representing a worker Pod and the execution capacity it advertises. Several actors may be active on it. | Chapters 1, 3 |
| WorkerPool | Kubernetes CRD that controls a worker fleet and its sandbox-class/configuration selection. | Chapters 2, 4 |
| SandboxConfig | Cluster-scoped CRD containing runtime versions and digest-addressed assets for a sandbox class. | Chapters 2, 5, 12 |
| CSIDriverConfig | Cluster-scoped configuration connecting Substrate volume handling to a CSI implementation. | Chapters 2, 5, 8 |
| ateapi / ate-api-server | Go command and deployment role implementing the actor control plane, PostgreSQL workflows, scheduling and associated controllers. | Chapter 3 |
| atecontroller | Kubernetes infrastructure reconciliation and Pod-to-Worker synchronization process. | Chapter 4 |
| atelet | Node supervisor that prepares local state and invokes the worker protocol, with support and storage coordination services. | Chapter 5 |
| ateworker | A runtime-specific worker process implementing Run/Checkpoint/Restore/Terminate and statistics. The baseline has gVisor and microVM implementations. | Chapters 5–7 |
| atenet-router | Ingress deployment role that resolves actor destinations and triggers resume, using the selected dataplane. | Chapter 9 |
| atenet-egress | Shared outbound gateway role performing identity, policy and credential handling outside actor sandboxes. | Chapters 9–10 |
| atunnel | Library embedded in the worker for per-actor ingress/egress transport and DNS behavior. | Chapter 9 |
| Lease | Renewable SQL ownership record used to serialize a workflow. It is not interchangeable with a row lock, assignment uniqueness, or worker epoch. | Chapter 3 |
| Worker epoch | Worker process incarnation used to reject/reconcile stale work across restarts. | Chapters 3, 5 |
| Authoritative admission | Capacity revalidation and booking inside the store transaction. Candidate selection alone is advisory. | Chapter 3 |
| Golden snapshot | Prepared starting state associated with a template's golden workflow, when configured. It is not implied for every possible cold start. | Chapters 3, 8 |
| Tag | A named retention/reference construct backed by its own copied external snapshot, with sharing and lifecycle semantics. | Chapters 2, 8, 10 |
| Fidelity | The state layers retained by a snapshot: VOLUMES, ROOTFS, or MEMORY. | Chapter 8 |
| VOLUMES | Snapshot fidelity retaining DurableDir contents, without promising process-memory continuation or all rootfs writes. | Chapter 8 |
| ROOTFS | Fidelity adding container writable-rootfs state to the durable-directory layer; processes cold-boot on restore. | Chapters 6–8 |
| MEMORY | Fidelity adding the execution image. It carries runtime compatibility constraints beyond filesystem recovery. | Chapters 6–8 |
| Locality | Retained node-local state that can constrain placement and avoid remote transfer. It is not itself an object-store durability guarantee. | Chapters 3, 8 |
| Durable snapshot | Completed external snapshot state tracked by the control plane, whose physical resilience depends on the configured storage backend. | Chapter 8 |
| Detach | Locality-release operation that may require upload before removing a local copy and allowing placement elsewhere. | Chapter 8 |
| Revert | Lifecycle operation returning an actor to its completed durable state while discarding current execution/local progress as defined by the workflow. | Chapters 3, 8 |
| OnDemand | Cloud Hypervisor restore mode that faults memory pages as needed. It is conditional in this baseline and not the default staged CH v53 path. | Chapter 7 |
| Copy | Eager guest-memory restoration mode selected by the current version policy for affected or unknown CH versions. | Chapter 7 |
| Sentry | gVisor userspace kernel hosting the actor's application execution abstraction. It is distinct from host Linux. | Chapter 6 |
| virtiofsd | Host process serving a filesystem tree to the guest over virtio-fs. Its memory and permissions are part of the microVM boundary. | Chapter 7 |
| Runtime asset cache | Node-local immutable binary/kernel/image cache, pinned by workers and actors according to use. | Chapter 5 |
| Snapshot file cache | Cache for shared restore files. Its identity, mutability and eviction rules differ from runtime assets and OCI layers. | Chapter 8 |
| RustFS | Existing S3-compatible alternative object-store deployment in the kind manifests. Its backend credentials and failure domains remain explicit operational concerns. | Chapters 8, 11 |
| Request parking | Bounded retention/retry of requests through eligible transient resume failures, with per-actor flight sharing. | Chapter 9 |
| SPIFFE identity | URI-based workload identity carried in certificates and used by specific authentication/authorization checks. It is not by itself an authorization policy. | Chapter 10 |
| EgressPolicy | Actor-related outbound policy evaluated outside the sandbox, including permitted requests and credential effects. | Chapter 10 |
| AccessPolicy | Substrate API authorization configuration using global/atespace scopes and the embedded relation model. | Chapter 10 |
| ext_proc | Envoy's external processing protocol. The operation being delegated and trusted metadata available depend on the filter chain. | Chapters 9–10 |
| Preview gate | Explicit opt-in for behavior whose availability should not be inferred merely from a schema field or implementation package. | Chapters 2, 12 |

## Follow a problem through the book

**A resume is slow.** Start with Chapter 11's end-to-end measurement boundary. Use Chapter 9 to distinguish parking and proxy work, Chapter 3 for admission/lease/store contention, Chapter 8 for locality and download, and Chapter 6 or 7 for the actual restore and readiness path. A runtime phase measurement cannot explain an earlier wait for capacity.

**A worker restarts while hosting actors.** Read Chapter 5's process/registration lifecycle, then Chapter 3's epoch and assignment reconciliation. Chapter 8 explains which local and external snapshot states remain usable. The existence of a checkpoint file is not sufficient evidence that the corresponding actor record should advertise it as durable.

**Memory use grows after many restores.** Separate actor bookings from host charges using Chapter 5. Read the backend-specific cgroup and memory discussion in Chapter 6 or 7, then snapshot cache/writeback behavior in Chapter 8. Include virtiofsd, host page cache, upload buffers, and concurrent checkpoint loans before concluding that the application leaked memory.

**An actor can reach an unexpected endpoint.** Follow the network namespace and NAT path in Chapter 9, then identity/policy/DNS and TLS interception in Chapter 10. Inspect the rendered dataplane configuration and active policy cache rather than reasoning from a single base manifest. An ingress allowlist and an egress allow rule protect different traffic directions.

**A RustFS deployment is unavailable.** Chapter 8 identifies node/control plugin operations that need it and what local locality can still satisfy. Chapter 11 treats object-store recovery, bucket access, credentials, endpoints, PVC persistence and shared infrastructure failure domains. A cache hit may conceal an outage for one actor while another actor cannot resume.

**A new runtime version is introduced.** Start with Chapter 12's compatibility contract and Chapter 4's SandboxConfig selection/protection. Chapter 5 explains asset publication and worker advertisement. Chapter 3 determines compatible placement; Chapters 6–8 determine which state can be reused or downgraded. A new worker image and a new sandbox binary are separate rollout events.
