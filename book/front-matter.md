# Agent Substrate

## Sandboxing, Scheduling, and Multiplexing AI Agents on Kubernetes

Source-grounded manuscript · Refreshed for v1.0.0 · November 9, 2026

Implementation baseline: `v1.0.0`, commit `b34fbee742906494b5eb4f1f36987176bf8770a4`. The first edition was written against `0ddbf78d54bb6da2ccb01125b7e085aa14d555a6`; this edition revises it against the release tag.

## Preface

Substrate puts a second scheduling and lifecycle system above Kubernetes. Kubernetes provisions worker Pods and supplies the surrounding infrastructure. Substrate assigns actors to those workers, restores their execution state, mediates their network traffic, and moves their snapshots between local storage and an object store. Understanding that division requires following several kinds of state at once: PostgreSQL records, Kubernetes objects, node-local bookkeeping, sandbox processes, filesystem objects, and authenticated network sessions.

This book follows those state transitions through a specific checkout. Its central questions are concrete. Which write establishes an actor assignment? Which process may still use a snapshot file after a restore returns? What prevents a worker restart from accepting instructions for an earlier incarnation? Which memory charge can kill a neighboring actor? Where is an outbound request authenticated, and where is its credential added? What survives losing a node, and what survives losing an object-storage deployment?

The answers cross component boundaries. A scheduler policy cannot establish exclusive assignment without a store transaction. A fast restore does not establish readiness until the guest can service the wakeup probe. An object-store acknowledgment establishes only the durability offered by that configured backend. A private network namespace does not decide whether an actor may contact a particular hostname. The book therefore treats the system as cooperating protocols rather than a list of binaries.

The intended reader already understands Kubernetes control-plane internals, reconciliation, container construction, namespaces, cgroups, and virtualization. Basic explanations appear only where a distinction changes Substrate behavior. The emphasis is on actual structs, interfaces, algorithms, failure sequences, resource accounting, and the cost of maintaining consistency while many actors share a smaller worker fleet.

## The source contract

Every implementation claim refers to the local repository baseline named above. Code links in the chapters point to the upstream repository at the `v1.0.0` tag, so every reference resolves on GitHub without a local clone. Generated public and internal protocols, deployment manifests, dependency pins, benchmark harnesses, tests, and relevant vendored wrappers are part of the evidence. A comment or documentation page is not treated as proof when executable code contradicts it.

The v1.0.0 tree has 14,019 tracked files, including 11,645 under `vendor/`. Deep inspection concentrated on first-party behavior and the dependency boundaries it exercises. That does not mean every line of every vendored library was manually reviewed. The complete syscall behavior of Go, Envoy, runsc, Cloud Hypervisor, virtiofsd, and a selected CSI driver cannot be established by searching Substrate's Go files. Appendix A identifies direct calls, library-mediated calls, and external-runtime mechanisms separately.

The v1.0.0 revision is the first release covered by the README's compatibility commitment and by the version-skew policy, which applies from 1.0.0 and covers compatible releases only. Its architecture document no longer carries a planned status, but its targets remain targets. There is no `docs/roadmap.md` in this revision. Roadmap discussions therefore cite explicit targets, preview gates, limitations, or source TODOs, and identify additional proposals as proposals.

The book contains no new performance measurements. Numbers from flags, manifests, algorithms, and configuration are implementation facts at the baseline. North-star latency and scale numbers are targets. Historical benchmark observations are identified as such when discussed. Capacity examples are worked models with stated assumptions, not claims about a measured cluster.

## What the book covers

Chapter 1 introduces Substrate's resource model and execution topology. Chapters 2 to 4 lay the foundation the rest of the book builds on: how containerd, runc and gVisor differ, how a Pod travels from `kubectl apply` through the API server, etcd, the scheduler and the kubelet, and how the node builds it on Linux with cgroups, namespaces, CNI, image unpacking and runc's system calls. Chapters 5 to 7 cover Substrate's control plane: its two API planes, placement and consistency in ateapi, and Kubernetes reconciliation. Chapters 8 to 11 descend to the node: node supervision, a complete trace of an actor's first start (the actor counterpart of Chapters 3 and 4), then the gVisor and microVM backends. Chapters 12 and 13 cover persistence: snapshot storage, then suspend and restore at the system-call level. Chapters 14 to 17 separate transport from authorization and credential handling, then cover measurement, operations, extension boundaries and upgrades.

Each chapter has six numbered sections. Section N.6 considers the subsystem's roadmap and engineering improvements. This keeps unfinished work adjacent to the mechanism it would change. The appendices collect the kernel audit, source inventory, implementation-status matrix, vocabulary, and a reference explaining every Linux command and system call used in Chapters 2 to 4, 9 and 13, with who calls it.

RustFS receives explicit treatment as an alternate object-store deployment through the S3 backend. The repository already includes a RustFS deployment, bucket-initialization Job, NetworkPolicy, and matching node/control plugin configuration for kind. Those files establish an integration path. Their single-replica deployment, small PVC, HTTP endpoint, and static development credentials do not establish a production availability or security design. The storage and operations chapters explain what changes when the object store shares infrastructure and failure domains with the compute fleet.

## Reading the diagrams and examples

Mermaid diagrams express ordering, ownership, and boundaries. An arrow labeled with an RPC means a protocol invocation, not a claim that the associated state transition is atomic with every adjacent arrow. Database transaction boundaries and persistence points are identified explicitly when they matter. State diagrams abbreviate error handling only when the accompanying text explains the omitted branches.

Code excerpts illustrate actual implementation decisions. Pseudocode is labeled and should not be compiled as an API example. Operational commands are tied to the repository's current tooling; environment-specific values remain placeholders. Commands shown for a runbook are instructions for a prepared environment, not a record of commands executed while writing the manuscript.

The source links are pinned to the `v1.0.0` tag, so they keep pointing at the same files. The companion and the reconnaissance notes are pinned to the first edition's commit, `0ddbf78d`, because their evidence was captured there. The manuscript is intended to make such comparison easier: changes to schema ownership, worker admission, snapshot fidelity, runtime compatibility, or identity scope should be visible as changes to a specific contract, rather than as vague changes to an architectural description.

## Publication and verification notes

This is a complete first manuscript, not a declaration that the software or prose has received an independent production certification. The publication checks verify chapter structure, source-link resolution, diagram rendering, cross-references, and actual word/page counts. They do not execute Kubernetes, KVM, CSI, cloud storage, or multi-node failure tests.

The project source retains its existing license and attribution. Short excerpts identify their source. No upstream source files were altered to make the narrative fit. The companion audit records important mismatches between older documentation and current behavior, including the conditional microVM demand-paging path and the absence of a wired automatic idle-suspension trigger.
