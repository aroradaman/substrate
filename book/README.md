# Substrate Internals

**Sandboxing, Scheduling, and Multiplexing AI Agents on Kubernetes**

A source-grounded technical manuscript for engineers who already know Kubernetes control-plane internals, Linux containers, and virtualization.

The implementation baseline is the `v1.0.0` tag, commit `b34fbee742906494b5eb4f1f36987176bf8770a4`, dated November 5, 2026. The first edition was written against commit `0ddbf78d54bb6da2ccb01125b7e085aa14d555a6`; this refresh revises it against the release. The manuscript distinguishes implementation, preview features, documented targets, and proposed engineering work. RustFS is covered as the existing S3-compatible storage alternative, alongside GCS and the node-local snapshot path.

This refreshed edition contains **12 chapters, 3 appendices, 299 PDF pages, and 57 Mermaid diagrams**. The assembled text has 87,620 words excluding fenced code and link destinations; the chapter source files contain 84,973 words including those elements. Validation resolves 570 local references, renders every figure, and checks HTML anchors and layout. Source and PDF hashes identify the exact reviewed artifact in `validation.json` and `render-validation.json`.

## Read the book

- [Complete HTML edition](substrate-internals.html)
- [Complete Markdown manuscript](manuscript.md)
- [Print edition](substrate-internals.pdf)
- [Front matter and reading guide](front-matter.md)
- [Source audit and blueprint decisions](reconnaissance.md)
- [Independent actor lifecycle: HTML](actor-lifecycle.html), [PDF](actor-lifecycle.pdf), [Markdown](actor-lifecycle.md)
- [Live deployment, network/cgroup, PostgreSQL and RustFS evidence](experiments/epc-20261031/README.md)

The independent lifecycle companion adds a real Linux kind deployment to the source-based book. It covers source builds and manifest construction, actor creation, checkpoint/suspend/resume, egress policy, actual namespaces and nftables, gVisor processes and cgroup ancestry, PostgreSQL schema and decoded rows, and RustFS object layout. Its host boundary begins at the Kubernetes node. The experiment includes its diagnostic failures and recovery; it is separate from the first edition's counts above.

## Chapters

1. [Multiplexing Actors: Architecture and Execution Boundaries](chapters/01-architecture.md)
2. [Two API Planes: Resources, Schemas, and Contracts](chapters/02-api-planes.md)
3. [Placement and Consistency in ateapi](chapters/03-placement-consistency.md)
4. [Reconciling Kubernetes Infrastructure](chapters/04-kubernetes-reconciliation.md)
5. [Node Supervision and Shared Worker Machinery](chapters/05-node-supervision.md)
6. [gVisor Execution and Checkpoint Internals](chapters/06-gvisor.md)
7. [MicroVM Execution with Kata and Cloud Hypervisor](chapters/07-microvm.md)
8. [Snapshot Persistence, Locality, and Storage Backends](chapters/08-snapshots-storage.md)
9. [Actor Networking, Transparent Resume, and Backpressure](chapters/09-networking.md)
10. [Identity, Authorization, and Credential Brokering](chapters/10-security-identity.md)
11. [Operating and Measuring a Multiplexed Fleet](chapters/11-operations.md)
12. [Extension Contracts and Upgrade Compatibility](chapters/12-extension-contracts.md)

## Appendices

- [A. Linux primitive and kernel-interface audit](appendix-a-kernel-audit.md)
- [B. Source inventory and implementation status](appendix-b-source-inventory.md)
- [C. Glossary and reading paths](appendix-c-glossary.md)

## Rebuild and verify

Run `python3 book/build.py` from the repository root. The builder checks chapter structure, upstream source links against their pinned refs, word counts, and duplicate prose, then assembles Markdown and HTML. Python dependencies are pinned in `book/requirements.txt`. The generated SVG figures make the HTML edition usable without a network connection.

`node book/render.mjs --tools /path/to/diagram-tools` renders Mermaid figures and prints the PDF using a locally installed Chrome or Chromium. The exact direct dependencies used for this edition are in `book/render-tools/package.json`; install them with lifecycle scripts disabled because an existing browser is used. For example, `npm install --prefix book/render-tools --ignore-scripts --no-audit --no-fund`, followed by `node book/render.mjs --tools book/render-tools`. Pass `--chrome /path/to/chromium` on a different platform. The renderer does not deploy the book or send manuscript content to a remote rendering service.

The build records actual counts and validation results in [validation.json](validation.json). A macOS PDFKit read records the 299 pages, all chapter/appendix starts, and 57 figure captions in [pdf-inspection.json](pdf-inspection.json). Page budgets are editorial estimates; the PDF page count is measured after typesetting. No benchmark result in the book was newly measured by building this manuscript.

Rebuild the independent companion with `python3 book/build.py --lifecycle` and `node book/render.mjs --lifecycle --tools /path/to/diagram-tools`. Its checks and hashes are recorded separately in `lifecycle-validation.json` and `lifecycle-render-validation.json`. The live experiment's small set of timings is documented with its actual measurement boundaries.
