# Manuscript contract

Title: **Substrate Internals: Sandboxing, Scheduling, and Multiplexing AI Agents on Kubernetes**.

The user authorized writing the complete book after the repository reconnaissance, explicitly requested whole-clone coverage, and asked to include RustFS as an alternative object store. This manuscript is grounded in local commit `0ddbf78d54bb6da2ccb01125b7e085aa14d555a6` (2026-10-31). Existing source code must not be changed.

Audience: Kubernetes core contributors who already understand controllers, CRI/CNI/CSI, namespaces, cgroups, and virtualization. Explain Substrate-specific decisions, contracts, races, failure recovery, costs, and limitations. Do not fill pages reteaching basic Kubernetes or generic cloud-native concepts.

Write continuous technical prose, with tables, short code excerpts, concrete execution traces, equations where useful, and mandatory Mermaid diagrams. Avoid filler, invented measurements, invented APIs, repeated summaries, and padding to hit a count. Runtime behavior wins over stale comments. Distinguish implemented behavior, preview features, documented targets/TODOs, and editorial proposals. Prefer readable relative source links from each chapter, for example `../../cmd/ateapi/main.go`. Give identifiers and filenames next to technical claims. For line citations, GitHub permalinks may use the audited full commit; local relative links should omit line fragments.

Each chapter has exactly six top-level numbered sections `## N.1` through `## N.6`. Subsections may use `###`. N.6 is titled **Roadmap and engineering improvements**, and must distinguish repository-backed work from proposals. Each chapter ends with a short unnumbered `## Source map` giving the important source files and the questions they answer. No seventh numbered section. Source maps and tables do not replace explanation.

Targets: about 84,600 words across 282 body pages at a planning density of 300 words/page, plus front matter/appendices/index budget of 18 pages. These are editorial targets, not a promise about final typography. Aim at the chapter counts below, count the actual words, and report any material shortfall. Never use repeated filler to satisfy a count.

| Chapter | File | Pages | Words |
|---|---|---:|---:|
| 1. Multiplexing Actors: Architecture and Execution Boundaries | 01-architecture.md | 20 | 6000 |
| 2. Two API Planes: Resources, Schemas, and Contracts | 02-api-planes.md | 22 | 6600 |
| 3. Placement and Consistency in ateapi | 03-placement-consistency.md | 25 | 7500 |
| 4. Reconciling Kubernetes Infrastructure | 04-kubernetes-reconciliation.md | 22 | 6600 |
| 5. Node Supervision and Shared Worker Machinery | 05-node-supervision.md | 24 | 7200 |
| 6. gVisor Execution and Checkpoint Internals | 06-gvisor.md | 24 | 7200 |
| 7. MicroVM Execution with Kata and Cloud Hypervisor | 07-microvm.md | 25 | 7500 |
| 8. Snapshot Persistence, Locality, and Storage Backends | 08-snapshots-storage.md | 25 | 7500 |
| 9. Actor Networking, Transparent Resume, and Backpressure | 09-networking.md | 25 | 7500 |
| 10. Identity, Authorization, and Credential Brokering | 10-security-identity.md | 25 | 7500 |
| 11. Operating and Measuring a Multiplexed Fleet | 11-operations.md | 24 | 7200 |
| 12. Extension Contracts and Upgrade Compatibility | 12-extension-contracts.md | 21 | 6300 |

Cross-chapter boundaries: 3 owns leases/CAS/outbox/epochs/scheduling and execution state; 8 owns snapshot state, tags, fidelity, durability, snapshot cache and backend I/O. 5 owns image/runtime asset caches and common worker machinery; 6/7 own backend-specific mechanics. 9 owns transport/routing/parking/DNS transport; 10 owns identity/policy/DNS enforcement/credential injection. 11 owns operational rollout execution; 12 owns compatibility and extension contracts.

Critical audit constraints:

- No `ateom`, `pkg/apis`, `config/`, `deploy/`, or `docs/roadmap.md` in this checkout. CRDs are in `api/infra/k8s/ate/v1`; YAML in `manifests`; architecture is `docs/concepts/architecture.md` and explicitly marked aspirational.
- Actor/ActorTemplate/Atespace/Worker/Tag/EgressPolicy/AccessPolicy are PostgreSQL API records; WorkerPool/SandboxConfig/CSIDriverConfig are CRDs. Multiple actors can execute concurrently per worker.
- Placement uses candidate selection from a cache, power-of-two choices and dominant utilization, then authoritative admission under a PostgreSQL worker row lock. Renewable SQL leases, unique assignments, worker epochs and recovery have separate roles.
- Golden-template and worker-assignment controllers run inside ateapi. Controller-runtime does not implement every controller in the repository.
- Automatic idle suspension is not wired into the runtime. `internal/ateworker/suspend` is scaffolding with no production constructor call. Do not portray inactivity detection as shipped.
- Default staged microVM assets are Kata 4.3.1 and CH v53.0. `restoreMemMode` selects eager `Copy` for CH >=53 or unknown versions due to prefault behavior; `OnDemand`/userfaultfd is conditional. Do not write that the default always demand-pages.
- Sparse delta merging is implemented for OnDemand restores, producing complete snapshots, not an object-store chain of incremental snapshots.
- Both worker pod classes are nonprivileged with explicit capabilities but seccomp and AppArmor Unconfined. Runtime self-confinement is a different boundary. gVisor is a userspace kernel.
- MicroVM rootfs upper is host-backed and exposed with virtio-fs; gVisor filesystem checkpoint bundles differ. Keep host Linux, pod runtime, Sentry, guest kernel, VMM and actor boundaries explicit.
- atenet-router/atenet-egress are deployment roles of shared atenet/Envoy machinery. atunnel is an embedded worker library. Envoy Rust dynamic modules and optional AgentGateway must be covered.
- Default actor routing uses `ate-target-actor`, preserves Host, and tunnels to worker atunnel. Arbitrary-port ingress supports HTTP(S) inside CONNECT, not arbitrary raw TCP.
- Ingress client SPIFFE allowlisting is not per-actor authorization. Egress allows RUNNING and RESUMING. GCS supports per-actor credential exchange; S3 currently uses plugin ambient credentials.
- RustFS is explicitly required. Inspect `manifests/ate-install/kind/rustfs.yaml`, kind node/control sidecar overlays, `pkg/objectstorage/env.go`, `s3.go`, and `cmd/ate-setup/internal/steps/microvm.go`. Present it as the existing S3-compatible alternate, with concrete endpoint/path-style configuration, data path, bucket initialization, credentials, NetworkPolicy, and failure-domain implications. The one-replica 1Gi PVC/static development-credential manifest is a development/CI example, not evidence of an HA production topology. Do not assert unverified RustFS product features.
- 100ms p95 activation, billion-actor scale, and 1000 wakes/s are targets. README claims and historical results are not fresh measurements. Benchmark mean+2σ is not p95. No cluster tests have been run for this manuscript.
- All source links must exist. Validate identifiers and examples. Executable commands must be actual current commands; otherwise label pseudocode. Avoid huge copied code blocks.

No commits, PRs, deployment, publication, or external messages are authorized or needed. Produce source manuscript only in `book/`; root agent will assemble publication artifacts and perform checks.
