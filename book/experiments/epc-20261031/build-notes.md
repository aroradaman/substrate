# Build and manifest provenance for the epc experiment

The source checkout is `/home/daman/substrate-lifecycle-20261031` at `0ddbf78d54bb6da2ccb01125b7e085aa14d555a6`. Experiment evidence is written under `/home/daman/substrate-lifecycle-evidence-20261031`. The Kubernetes context is `kind-substrate-lifecycle`, the cluster name is `substrate-lifecycle`, and images are pushed to the experiment registry at `localhost:5002`.

The commands below describe this experiment. Source-derived installation behavior is identified separately from observations. A captured Kubernetes object has already passed API defaulting, admission, and reconciliation; it does not reproduce the exact manifest bytes that the installer submitted.

## Recorded commands and configuration

[01-build.sh](scripts/01-build.sh) builds the two native tools from the checkout:

```sh
go build -p=8 -o "$TASK_EVIDENCE/bin/ate-setup" ./cmd/ate-setup
go build -p=8 -o "$TASK_EVIDENCE/bin/kubectl-ate" ./cmd/kubectl-ate
hack/kind.sh version
```

The script records `go version -m` for both binaries. [02-kind.sh](scripts/02-kind.sh) invokes `hack/create-kind-cluster.sh`, with the cluster name and registry port set by [common.sh](scripts/common.sh). It preserves the generated `bin/kind-config.yaml` and selected node/container identity evidence. The private kubeconfig stays in the evidence directory and is excluded from the shareable capture.

[03-deploy.sh](scripts/03-deploy.sh) invokes:

```sh
ate-setup deploy ate-system \
  --kind --kind-cluster-name=substrate-lifecycle \
  --ko-docker-repo=localhost:5002 --sandbox-classes=gvisor \
  --credential-provider='{"name":"k8s.io"}' \
  --ingress-allowed-spiffe-ids=spiffe://cluster.local/ns/ate-system/sa/atenet-client

ate-setup deploy demo counter \
  --kind --kind-cluster-name=substrate-lifecycle --ko-docker-repo=localhost:5002

ate-setup deploy demo egress \
  --kind --kind-cluster-name=substrate-lifecycle --ko-docker-repo=localhost:5002
```

`common.sh` records command arguments, UTC start/end times, exit status, logs, and `/usr/bin/time -v` output. Those timings describe complete commands, including image builds and rollout waits. They are not actor-resume measurements. The full-system deployment completed successfully from 17:49:03 to 17:53:15 UTC on 2026-10-31, a 252-second interval. Demo and lifecycle outcomes are recorded separately in the experiment report.

The main module and pinned tool modules request Go 1.27.3. The first capture observed effective `go version go1.27.3 linux/amd64` inside the source directory. Go's automatic toolchain selection means invoking `/usr/local/go/bin/go` there still reports the selected module toolchain. The final capture ran that launcher with `GOTOOLCHAIN=local` and observed Go 1.27.1, distinguishing its installed version from the effective 1.27.3 build toolchain. The source pins ko 0.19.1 and kind 0.33.0. An unrelated `kind` found on the host PATH reported `0.34.0-alpha.1356+214d9fd1426470`; it must not be substituted for the pinned wrapper's version when describing cluster creation. The captured Docker client/server version was 29.7.2, and buildx reported v0.37.0.

## How the installer constructs images

The default image source is a local source build. `--image-repo` would select prebuilt images, but this invocation does not supply it. [images.go](../../../cmd/ate-setup/internal/images/images.go) defines the component packages and image naming. [env.go](../../../cmd/ate-setup/internal/steps/env.go) creates either the ko runner or the prebuilt resolver and passes every component manifest through preview-argument injection before image resolution.

The [ko runner](../../../cmd/ate-setup/internal/ko/ko.go) locates the pinned executable using `go tool -n ko` from `hack/tools/ko`. It invokes `ko resolve -f <path>` or `ko resolve -f -`, with `--base-import-paths` and linker stamps for version, commit, and commit time. The latter is the build-date value used for source image binaries. `KO_DOCKER_REPO` supplies the registry. Worker images that are referenced through WorkerPool fields can also use `ko build <import-path>` rather than manifest resolution. Resolved manifest references use digests.

[.ko.yaml](../../../.ko.yaml) pins the base images and normally lists both Linux architectures. For this kind deployment, [applyKindDefaults](../../../cmd/ate-setup/internal/config/load.go) chooses `linux/` plus the native architecture unless a flag or configuration file explicitly overrides the platforms. That gives linux/amd64 on epc. It also selects the experiment context and local storage defaults while avoiding ambient GKE storage settings. The profile uses the logical snapshot location `gs://ate-snapshots/`; the selected plugin backend and endpoint determine where those bucket/object coordinates are stored. The kind overlays configure the S3 backend against RustFS.

Envoy is a separate Dockerfile build. [dockerfile.go](../../../cmd/ate-setup/internal/images/dockerfile.go) invokes `docker buildx build --platform=<platforms> --push --metadata-file <temporary-file> ... -t <repo>/envoy-dataplane:build-<timestamp> <context>`. It reads `containerimage.digest` from buildx metadata and returns a digest-pinned image reference. [The Dockerfile](../../../cmd/dataplane/envoy/Dockerfile) builds the Rust dynamic module with `cargo build --release --locked`, then copies it into the pinned Envoy runtime image. Its package installation occurs inside the builder image. The installer caches the resulting reference within one invocation so ingress and egress use that build.

Pod `.spec.containers[].image` records the configured reference. Pod status `imageID` records the runtime-reported pulled identity. The capture preserves both: they can differ in representation, especially for image indexes and platform manifests. Neither should be inferred from a mutable registry tag after the run.

## Why a gs:// snapshot URI reached RustFS

The observed `gs://ate-snapshots/...` URI is expected in this kind profile. It does not prove that the bytes went to Google Cloud Storage. [applyKindDefaults](../../../cmd/ate-setup/internal/config/load.go) sets `storage.snapshotLocation` to `gs://` plus the local bucket name. [ValidateSnapshotLocation and parseStorageURI](../../../internal/resources/validate.go) check the bucket and safe path shape but deliberately do not enforce a scheme. [SnapshotURI](../../../internal/resources/snapshot.go) adds actor/tag ownership segments while retaining that location string.

The node plugin validates the snapshot address and passes each file through the configured `ObjectStorage` implementation. The historically named [parseGCSURL](../../../pkg/objectstorage/objects.go) parses the URI and returns only its host as the bucket and its path as the object key. It does not select the backend. [NewFromEnv](../../../pkg/objectstorage/env.go) selects S3 when `ATE_STORAGE_BACKEND=s3`, and the S3 client uses the configured AWS endpoint. [s3Client.PutObject](../../../pkg/objectstorage/s3.go) then sends those bucket/key coordinates through the AWS S3 API. For this experiment, `gs://ate-snapshots/atespaces/...` is consequently a logical snapshot address for bucket `ate-snapshots` in RustFS.

The control-side copy/delete path follows the same separation. [newObjectStore](../../../cmd/objectstore-plugin/main.go) selects `objectstore.NewS3` from the backend environment. [BucketPrefix](../../../internal/objectstore/objectstore.go) extracts bucket and key prefix from the URI; the S3 implementation performs ListObjectsV2, CopyObject or multipart copy, and DeleteObject against that configured endpoint. No HTTP request is sent to a `gs://` endpoint, and the URI is not rewritten in actor status merely because the plugin uses S3.

This behavior must not be generalized to every URI in the system. Runtime asset fetches have a separate scheme contract: the S3 plugin's `assetScheme()` is `s3`. A `gs://gvisor/...` runtime asset can instead use atelet's restricted anonymous GCS fallback. Snapshot storage and runtime-asset retrieval therefore need separate evidence. The RustFS snapshot proof below establishes snapshot and tag objects, without claiming that every runtime asset came from RustFS.

The live capture independently checked the deployed selectors. Both API Pods' `objectstore-plugin` sidecars and the atelet Pod's restartable-init `objectstore-plugin` sidecar had `ATE_STORAGE_BACKEND=s3` and `AWS_ENDPOINT_URL=http://rustfs.ate-system.svc:9000`. Only those two environment values, Pod name, and container name were exported to `provenance/deployed-storage-backends.json`. Credentials were not included.

## How manifests become API writes

[DeployAteSystem](../../../cmd/ate-setup/internal/steps/deploy.go) first validates configuration, checks for existing worker Pods, creates the system namespace, and applies generated CRDs/RBAC. It waits for CRDs to become Established and refreshes discovery. It then applies the SandboxConfig validating admission policy and the selected gVisor SandboxConfig. The microVM preparation and asset-publishing branch is not selected in this experiment.

The installer establishes API prerequisites, creates signer CA pools, deploys the PodCertificate controller and waits for trust bundles, applies telemetry configuration, and deploys the selected PostgreSQL configuration. Secret generation and application are necessary installation steps, but Secret content is not part of the shareable experiment evidence.

The [overlay selection](../../../cmd/ate-setup/internal/steps/overlay.go) chooses `manifests/ate-install/kind` for kind plus the default Envoy dataplane. The [kind kustomization](../../../manifests/ate-install/kind/kustomization.yaml) includes API/atelet overlays, controller, IDP, ingress router, NetworkPolicies, RustFS, OpenTelemetry collector, and Prometheus. PodCertificate deployment and egress deployment have separate apply paths. RustFS bucket initialization is part of the kind resources.

Rendering uses the in-process [Kustomize library](../../../cmd/ate-setup/internal/kustomize/kustomize.go), with `LoadRestrictionsNone` because overlays reference base resources outside their directory. Optional components are composed in a temporary kustomization. The installer patches the IDP issuer and ingress SPIFFE allowlist, substitutes the built Envoy digest, injects enabled preview arguments, and resolves `ko://` references. It adds the API environment hash to the API Deployment before applying. The hash makes an environment-source change visible as a Pod-template change; it is not a public dump of environment values.

After the system bundle, the installer ensures the egress MITM CA pool, deploys the selected Kubernetes Secrets credential provider, and renders/applies egress with provider connection flags and the Envoy digest. It then waits for API, IDP, controller, ingress, egress, atelet, and the selected credential provider to roll out. A successful full-system command includes those waits; it does not imply that demo workers or actors have already been created.

[kube.Apply](../../../cmd/ate-setup/internal/kube/apply.go) sends objects sequentially through client-go server-side apply, with field manager `ate-setup` and forced field ownership. It retries selected transient API errors and invalidates discovery after CRDs. It does not delegate apply to `ko` or `kubectl`. Intermediate rendered bytes and buildx metadata live in memory or temporary files and are not automatically preserved as a complete pre-admission bundle.

## Demo templates cross two resource APIs

[Substrate.Deploy](../../../cmd/ate-setup/internal/demos/substrate.go) renders the counter or egress WorkerPool template, resolves image references, and applies the namespace and WorkerPool through Kubernetes. It waits for the generated worker Deployment. It separately opens an authenticated Substrate API client, ensures the atespace, resolves the ActorTemplate image, and creates the ActorTemplate through the Control API. ActorTemplates and golden snapshots are not Kubernetes CRDs.

[render.Template](../../../cmd/ate-setup/internal/render/render.go) expands explicitly supplied placeholders and removes lines for disabled optional placeholders. The counter invocation does not enable external volumes, so those placeholder lines are removed. Each demo waits for its golden snapshot. That setup warms image/runtime caches before later actor experiments, which must be considered when describing cold-start results.

The controller subsequently renders worker Deployments from WorkerPool objects. Those Pods include controller-derived identities, devices, mounts, resource projections, and defaults. Their applied specifications are another stage beyond the source demo template. Source inputs, installer-generated writes, API-defaulted objects, and controller-generated objects are related evidence with different meanings.

## Safe capture and its limits

[capture-manifests.sh](scripts/capture-manifests.sh) performs only Kubernetes reads and local evidence writes. It requires the expected source revision, uses the explicit experiment context, and creates a timestamped capture directory. It collects selected workload/network/config/RBAC resources in the system and demo namespaces, Substrate CRDs/configuration, selected cluster policies, node version/capacity summaries, Pod image IDs, and tool/build metadata. It hashes tracked installer, template, module, and Dockerfile inputs without exporting their contents.

The script never requests Secret objects or reads kubeconfig, private installer records, Docker credentials, or arbitrary environment variables for publication. It redacts ConfigMap values, literal environment values, command/argument arrays, HTTP header values, URL fields, and annotations; it removes status from manifest exports. Separate Pod summaries retain only identity, image, readiness, restart, and bounded state fields. Secret references remain because they describe wiring without disclosing the referenced data.

The first successful capture started at 17:53:17 UTC, just after the system deployment completed. It found 29 workload objects in `ate-system`; this count includes multiple workload kinds and is not a Pod count. The manifest-only capture at 17:55:52 UTC is `manifests/capture-20261031T175552Z`. It contains 16 manifest JSON files and 132 selected objects, including WorkerPools `ate-demo-counter/counter` and `ate-demo-egress/egress`. A validation pass checked JSON parsing, absence of Secret objects, removal of status/annotations, and redaction of literal environment values, commands, arguments, and ConfigMap values. `bash -n` and ShellCheck passed for the capture script. Each collection is sequential rather than an atomic cluster snapshot. The JSON exports are deliberately redacted and are not directly replayable manifests. Raw experiment logs and unredacted Pod JSON remain private until separately reviewed.

For an exact pre-admission manifest archive, the installer would need to record each final apply input at the point immediately before `kube.Apply`, with credential handling designed for that archive. This experiment does not modify the installer to add that instrumentation. The source revision, explicit invocation, input hashes, built image references, command records, and redacted live resources provide provenance without claiming byte-for-byte reconstruction of missing intermediate manifests.

## Observed RustFS objects and snapshot manifests

The extended capture ran as `TASK_LIST_RUSTFS=1 bash capture-manifests.sh`. It opened an ephemeral loopback-only port-forward to `service/rustfs`, loaded the existing `rustfs-bucket-init` Job's development credentials into process memory, and issued signed, read-only S3 requests. It stopped the port-forward on exit. It created no Kubernetes resource and installed no host tool. The only object bodies requested were keys ending in `/manifest.json`, capped at 1 MiB. Memory images, rootfs archives, durable-directory contents, and certificate files were not downloaded.

The successful capture directory is `manifests/capture-20261031T180034Z`. At 18:00:36 UTC, ListObjectsV2 returned 52 objects in bucket `ate-snapshots`, totaling 9,275,995 stored bytes. `provenance/rustfs-objects.json` contains only bucket, key, and size, with capture metadata. `provenance/rustfs-manifests.json` contains selected fields from five actual manifest responses: sandbox class, source actor/template identifiers, file lists, fidelity, and runtime asset SHA-256. Asset URLs and unknown manifest fields are omitted. This is direct evidence of snapshot objects served by the deployed RustFS service, beyond the intent expressed by its manifests.

| Observed prefix below bucket ate-snapshots | Objects | Stored bytes |
|---|---:|---:|
| `atespaces/ate-demo-counter/actors/92c54efa-a098-47c4-93f1-f17bd3730c1a/snapshots/bab690e0-d67d-4bd3-91cb-7f088fb604bf/` | 12 | 2,656,137 |
| `atespaces/ate-demo-counter/tags/48abb3b2-88ff-442f-ae67-3860b9b26867/` | 12 | 3,193,744 |
| `atespaces/ate-demo-counter/tags/9d10cdd3-4d52-4a09-b94f-a0227f6bebf5/` | 12 | 2,599,654 |
| `atespaces/ate-demo-egress/actors/8fe5de26-cc8a-40e4-aa86-770a6bd8c43e/snapshots/7a91badb-26b4-437b-915b-3d2ada473b50/` | 8 | 460,060 |
| `atespaces/ate-demo-egress/tags/11c4465b-dd9c-4b29-ad27-6ade7a0a994a/` | 8 | 366,400 |

The counter actor's manifest identifies `lifecycle-counter`, actor UID `92c54efa-a098-47c4-93f1-f17bd3730c1a`, template `ate-demo-counter/counter`, fidelity `memory`, and the gVisor asset SHA-256 `708afc62f2ee82d19930c703e85f9dab4f27a78c0aec40c0f55eb1040107f1a7`. Its data files are `checkpoint.img`, `pages.img`, `pages_meta.img`, four `rootfs/` files, and four `fs/` files. The latter are the `dataSnapshotFiles` that independently support VOLUMES fidelity. The egress snapshot has the process-memory and rootfs groups but no separate durable-directory group.

[NodePlugin](../../../internal/objectstoreplugin/node.go) stores each data file under its name plus `.zstd`, while `manifest.json` remains uncompressed. Thus a manifest entry `fs/pages.img` maps to object key `<snapshot-prefix>/fs/pages.img.zstd`. The manifest is the commit marker and is uploaded after the requested data files succeed. The listed sizes describe this stored representation; they are not actor RSS, uncompressed checkpoint sizes, or restored working-set measurements.

The ownership segments have precise meanings. `actors/<actor-uid>/snapshots/<snapshot-uuid>/` identifies one checkpoint owned by an Actor incarnation. `tags/<tag-uid>/` identifies the one independently owned snapshot of a Tag incarnation. The resource names `lifecycle-counter` or `lifecycle-checkpoint` are not the ownership keys. Deleting and recreating a resource under the same name produces a different UID and therefore a different prefix. [NewSnapshotName](../../../internal/resources/snapshot.go) generates a UUID; the snapshot generation is a separate increasing integer assigned by [ensureMarkedSuspending](../../../cmd/ateapi/internal/controlapi/workflow_suspend.go). To connect a database/API generation to a bucket prefix, join the actor's snapshot record on its `uuid` and durable `snapshotUri`. A generation cannot be recovered by decoding the UUID or reading these manifest fields.

A copied tag preserves the source manifest content. The observed tag prefix `48abb3b2-88ff-442f-ae67-3860b9b26867` contains a manifest naming source actor UID `92c54efa-a098-47c4-93f1-f17bd3730c1a`; that is not a contradiction. [CopyPrefix](../../../internal/objectstore/objectstore.go) copies each source object into the tag-owned prefix, and [s3Store.Copy](../../../internal/objectstore/s3.go) performs the copy without rewriting manifest metadata. The tag's ownership UID belongs to the path and API Tag record; the manifest records the capture's original actor. A clone can initially reference that tag-owned snapshot without creating a clone-owned object prefix. Its later checkpoint gets a new snapshot under its own actor UID.

The current actor snapshot and the copied tag have different byte counts because the actor was checkpointed again after the tag was created. The tag is not an alias for whatever checkpoint is newest. The database/API records and lifecycle observations establish which generation was tagged and which snapshot a clone resumed. This object listing establishes the stored prefixes and selected capture metadata at its timestamp; it does not, by itself, prove that a particular restore fetched remote bytes instead of using a local cache.

The final correlation capture is `manifests/capture-20261031T180401Z`, with its RustFS listing timestamped 18:04:04 UTC. It again contains 52 objects and five selected manifests, now totaling 9,245,407 stored bytes. The counter prefix changed to `atespaces/ate-demo-counter/actors/92c54efa-a098-47c4-93f1-f17bd3730c1a/snapshots/79ade422-1ec9-4857-9e67-d9f1a9f74c97/`, containing 12 objects and 2,625,549 stored bytes, including the 723-byte manifest. The SQL/API experiment maps this UUID to generation 9: the actor was RUNNING at resource version 35 with generation 8 (`bab690e0-d67d-4bd3-91cb-7f088fb604bf`), SUSPENDED at version 37 with generation 9, and RUNNING again at version 39 with generation 9; the counter advanced from 10 to 11. The earlier 18:00:34 capture remains evidence for generation 8. Together these records join actor UID, database/API generation, snapshot UUID, and actual RustFS key prefix without treating the generation as part of the object name. The listing is an observation after the persistence experiment, not a separate checkpoint operation.
