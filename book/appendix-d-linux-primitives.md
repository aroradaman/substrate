# Appendix D. Linux Commands and System Calls, Explained

This appendix gives a short explanation of every Linux command and system call that appears in Chapters 2, 3, 4, 9 and 13. It also says who invokes each one on the Pod path and on the actor path. *Pod* means the ordinary Kubernetes path through the kubelet, containerd, CNI and runc. *Actor* means Substrate's path through atelet, the worker and runsc. Where an entry says "runsc", the pinned gVisor runtime performs it on Substrate's behalf, and the exact sequence belongs to that release. Appendix A audits Substrate's kernel interfaces by source file; this appendix is organized by primitive, for readers who want to know what each name means.

## Namespaces and process creation

**`clone` / `clone3`** create a new process or thread. Flags decide what the child shares with its parent and which new namespaces it gets: `CLONE_NEWNS` (mount), `CLONE_NEWPID`, `CLONE_NEWNET`, `CLONE_NEWUTS`, `CLONE_NEWIPC`, `CLONE_NEWUSER` and `CLONE_NEWCGROUP`. `clone3` can also place the child directly into a cgroup with `CLONE_INTO_CGROUP` and return a pidfd. *Pod:* runc's `nsexec` and Go runtime use it to create `runc init` and the container's PID 1. *Actor:* runsc uses it to create the Sentry, gofer and stub processes in new namespaces; the worker uses it, through Go's `os/exec`, to run runsc.

**`unshare` (system call)** moves the *calling* thread or process into new namespaces without creating a child. For a PID namespace it affects only future children. *Pod:* containerd calls `unshare(CLONE_NEWNET)` on a locked thread to create a Pod's network namespace, and runc's `nsexec` uses it for the container's namespaces. *Actor:* the worker's [netns.go](https://github.com/agent-substrate/substrate/blob/v1.0.0/internal/netns/netns.go) uses it to create each actor's runtime and gateway network namespaces.

**`unshare` (command)** is the util-linux command that runs a program in new namespaces, for example `unshare --net --mount --pid --fork bash`. It is a manual tool for experimenting with what runc and runsc automate; neither path runs the command.

**`setns`** moves the calling thread into an existing namespace given a file descriptor, from `/proc/<pid>/ns/<type>` or a bind-mounted namespace file. Mount and user namespaces require a single-threaded caller. *Pod:* runc's `nsexec` joins the pause container's network, IPC and UTS namespaces; CNI plugins enter the Pod namespace to configure `eth0`. *Actor:* the worker enters actor namespaces on locked OS threads to program interfaces and create namespace-bound sockets.

**`nsenter`** is the command-line wrapper around `setns`: `nsenter --target <pid> --net ip addr` runs `ip addr` inside the network namespace of `<pid>`. It is an operator tool. The lifecycle experiment's collectors use it with `--net=<path>` to inspect actor namespaces.

**`ip netns`** manages *named* network namespaces. `ip netns add x` performs `unshare(CLONE_NEWNET)` and bind-mounts the namespace onto `/run/netns/x` so it persists without a process; `ip netns exec x cmd` performs `setns` and runs a command. containerd and Substrate's worker implement the same technique in Go, so their namespaces appear as files under `/var/run/netns` (Pods, node view) or `/run/netns` inside the worker's mount namespace (actors).

**Namespace files and bind mounts.** Every namespace is visible as a magic link under `/proc/<pid>/ns/`. Bind-mounting it to an ordinary file keeps the namespace alive after all member processes exit, because the mount holds a reference. Removing the mount (`umount`) and closing all descriptors destroys it. This is how both containerd and the worker give network namespaces lifetimes independent of processes.

**PID namespace.** A process tree with its own PID numbering; the first process is PID 1, receives orphans and must reap them, and its exit kills the namespace. *Pod:* each container normally has its own, or the Pod shares pause's when `shareProcessNamespace` is set. *Actor:* runsc puts the Sentry in its own PID namespace on the host; the application's PIDs exist only inside the Sentry.

**Mount namespace.** A private copy of the mount table, so mounts made inside are invisible outside, subject to propagation settings. Each runc container and each runsc process gets one. The worker's own mount namespace is where actor network namespace files and bundle mounts live, which is why operators reach them through `/proc/<worker-pid>/root/`.

**UTS and IPC namespaces** isolate hostname/domainname and System V IPC plus POSIX message queues. Pod containers share pause's, which is why containers in a Pod see the same hostname.

**User namespace** maps user and group IDs. A process can be root with full capabilities *inside* while unprivileged outside. Writing `uid_map`/`gid_map` that maps ID 0 requires `CAP_SETFCAP` in the parent namespace since Linux 5.12. *Actor:* runsc places the gofer and systrap processes in an identity-mapped user namespace when directfs is on, which is why the worker Pod needs `SETUID`, `SETGID` and `SETFCAP` but not `SYS_PTRACE` or `SYS_CHROOT`.

**cgroup namespace** virtualizes the view of `/proc/self/cgroup` and the cgroup filesystem root, so a container sees its own cgroup as `/`. This explains why `/sys/fs/cgroup` inside the worker is not the node's cgroup root.

## Filesystems and mounts

**`mount`** attaches a filesystem or bind-mounts a directory. Flags such as `MS_BIND`, `MS_REC`, `MS_RDONLY` and `MS_REMOUNT`, and the propagation flags `MS_PRIVATE`, `MS_SLAVE` and `MS_SHARED`, select the operation. *Pod:* the kubelet mounts tmpfs for projected volumes, the shim mounts the overlay rootfs, and runc mounts `proc`, `sysfs`, `/dev` and volumes. *Actor:* the worker bind-mounts namespace files and prepared paths, and runsc's gofer sets up the container filesystem view.

**Mount propagation.** Shared mounts replicate mount events to peers, slave mounts receive but do not send, and private mounts do neither. runc makes the container root private or slave (`mount --make-rprivate /`) so container mounts never leak into the host.

**`umount2`** detaches a mount; with `MNT_DETACH` it is lazy, removing the mount from the namespace immediately and finishing when it is no longer busy. runc detaches the old root after `pivot_root`. Substrate's image cache detaches actor bundle mounts before deleting directories ([mountinfo.go](https://github.com/agent-substrate/substrate/blob/v1.0.0/internal/imagecache/mountinfo.go)).

**`pivot_root`** swaps the process's root mount with another mount point and moves the old root beneath it. Unlike `chroot`, it changes the mount namespace's root, so the old root can be fully detached and is unreachable. runc calls `pivot_root(".", ".")` from inside the new rootfs; runsc's gofer uses it to confine itself to the container root.

**`chroot`** changes only the calling process's root directory for path resolution. Escapes exist for privileged processes, so containers prefer `pivot_root`. The gVisor Sentry `chroot`s into an empty directory so it cannot name any host path at all.

**overlayfs** merges read-only lower directories with a writable upper directory. It uses a `workdir` for atomic copy-up, whiteout device nodes for deletions and the `trusted.overlay.opaque` xattr for replaced directories. *Pod:* containerd's overlayfs snapshotter builds every container rootfs this way. *Actor:* Substrate's image cache composes cached layers plus an actor-private upper.

**`fsopen`, `fsconfig`, `fsmount`, `move_mount`** form the descriptor-based mount API added in Linux 5.2. `fsopen("overlay")` returns a filesystem context, `fsconfig` sets each option (`lowerdir`, `upperdir`, `workdir`) separately, avoiding the page-size limit of a single option string, `fsmount` creates a detached mount object, and `move_mount` attaches it. *Actor:* [bundle_linux.go](https://github.com/agent-substrate/substrate/blob/v1.0.0/internal/imagecache/bundle_linux.go) uses this sequence for actor root filesystems.

**`mount` (command) and `findmnt`** show and change mounts from a shell; `/proc/self/mountinfo` is the authoritative per-namespace mount table that both commands read.

**Hard links, `rename`, `renameat2(RENAME_EXCHANGE)`, `unlink`.** A hard link is another name for the same inode, and the inode is freed when the last name and the last open descriptor are gone. `rename` atomically replaces one name. `RENAME_EXCHANGE` atomically swaps two names. Substrate uses hard links to share golden snapshot and asset files, and `RENAME_EXCHANGE` to publish a fetched asset ([exchange_linux.go](https://github.com/agent-substrate/substrate/blob/v1.0.0/pkg/assetfetch/exchange_linux.go)). containerd's content store uses rename to commit verified blobs.

## cgroups

**cgroup v2 filesystem.** Resource control is a hierarchy of directories under `/sys/fs/cgroup`. `mkdir` creates a cgroup and `rmdir` removes an empty one, reparenting its charges. Writing a PID to `cgroup.procs` moves a process, and writing to `cgroup.subtree_control` enables controllers for children. *Pod:* the kubelet (directly or through systemd) creates QoS and Pod slices, and runc creates the container scope. *Actor:* the worker delegates the worker container's scope and creates `worker`, `<uid>-_sandbox` and transient `<uid>-_ckpt` leaves; runsc uses the sandbox leaf named in the OCI specification.

**`cpu.max`, `cpu.weight`** set a quota per period (for example `100000 100000` = one CPU) and a proportional share. **`memory.max`** is a hard limit that triggers reclaim and then the OOM killer. **`memory.high`** is a throttling threshold that applies heavy reclaim pressure but does not kill; Substrate swaps the sandbox's `memory.max` for `memory.high` so an actor at its limit slows down instead of dying. **`pids.max`** limits task count.

**PSI (`memory.pressure`, `cpu.pressure`, `io.pressure`)** reports the share of time tasks were stalled on a resource. The worker's memory watcher uses memory pressure, together with **`memory.events.local`** (counts of high, max and OOM events in this cgroup only), to decide when to intervene.

**`cgroup.kill`** kills every process in a cgroup atomically by writing `1`. The worker's memory guard uses it to terminate an actor whose sandbox stays over its memory threshold.

**systemd scopes and slices.** With the systemd cgroup driver, the kubelet and runc ask systemd over D-Bus to create `.slice` and `.scope` units instead of creating directories directly; the names `kubepods-burstable-pod<uid>.slice` and `cri-containerd-<id>.scope` come from this.

## Security and privilege

**Capabilities and `capset`.** Root's powers are split into about forty capabilities. A process has permitted, effective, inheritable, bounding and ambient sets. `capset` changes the first three, and `prctl(PR_CAPBSET_DROP)` removes entries from the bounding set permanently. runc applies the container's capability set this way. Substrate's worker Pods receive an explicit capability list from the WorkerPool controller instead of privileged mode.

**`prctl(PR_SET_NO_NEW_PRIVS)`** guarantees that `execve` can never grant more privileges, so set-UID binaries and file capabilities stop working. It is required for unprivileged seccomp filters. runc sets it for containers; the Sentry and gofer report `NoNewPrivs: 1`.

**`seccomp` / `prctl(PR_SET_SECCOMP)`** installs a BPF program that inspects every system call's number and arguments and returns allow, `ERRNO`, `KILL`, `TRAP` (deliver `SIGSYS`) or `USER_NOTIF`. *Pod:* runc installs the runtime's default profile when `RuntimeDefault` is selected. *Actor:* runsc installs filters on the Sentry and gofer limiting them to the host calls they need, and systrap uses `SECCOMP_RET_TRAP` in stub processes to divert application syscalls to the Sentry. The worker Pod itself runs with seccomp Unconfined.

**AppArmor and SELinux** are Linux Security Modules that confine programs by profile or label. runc selects the profile by writing to `/proc/self/attr/apparmor/exec` before `execve`. Substrate's worker Pods run AppArmor Unconfined; the inner sandbox's confinement comes from gVisor.

**`setuid`, `setgid`, `setgroups`, `setresuid`** change the process's user and group identity. runc calls them last, after operations that needed root, so the workload runs as the image or Pod user.

**`prctl(PR_SET_CHILD_SUBREAPER)`** makes a process adopt orphaned descendants instead of PID 1 of the namespace. containerd shims use it to collect exit statuses. Substrate's worker PID 1 ([pid1.go](https://github.com/agent-substrate/substrate/blob/v1.0.0/internal/ateworker/pid1/pid1.go)) uses it to reap runsc helpers.

**`prctl(PR_SCHED_CORE)`** manages core scheduling cookies so tasks from different trust domains do not run simultaneously on sibling hyperthreads. The worker queries support and enables runsc core tags when available.

## Processes and signals

**`execve`** replaces the calling process's program with a new one, keeping its PID, namespaces, cgroup and descriptors not marked close-on-exec. It is the last step of runc's init. Under gVisor, application programs are loaded by the Sentry's own ELF loader; the host `execve` runs only runtime binaries.

**`wait4` / `waitid`** collect a child's exit status and release its zombie entry. The pause container, containerd shims and Substrate's PID 1 all reap with these calls.

**`kill`, `tgkill`, signals.** `SIGTERM` requests graceful shutdown and `SIGKILL` forces it. The kubelet's grace period is implemented by the shim sending one and then the other. `runsc kill` delivers signals to tasks inside the Sentry rather than to host processes.

**`pidfd_open`, `pidfd_send_signal`, `poll` on a pidfd.** A pidfd is a file descriptor that refers to one specific process. It becomes readable when that process exits and can be used to signal it without the risk of hitting a recycled PID. The worker opens a pidfd for each Sentry ([pidfd.go](https://github.com/agent-substrate/substrate/blob/v1.0.0/internal/pidfd/pidfd.go)).

**`pause()`** suspends the caller until a signal arrives. The pause container's main loop is a call to `pause()` in an infinite loop.

## Networking

**rtnetlink** is the socket-based kernel interface (`AF_NETLINK`, `NETLINK_ROUTE`) for links, addresses, routes and neighbours. `RTM_NEWLINK` creates interfaces such as `veth` and `bridge`, or changes them: up/down, master, namespace through `IFLA_NET_NS_FD`. `RTM_NEWADDR` assigns addresses and `RTM_NEWROUTE` adds routes. The `ip` command is a client of rtnetlink. *Pod:* CNI plugins. *Actor:* the worker's [sandbox.go](https://github.com/agent-substrate/substrate/blob/v1.0.0/internal/ateworker/actornet/sandbox.go).

**`ip link`, `ip addr`, `ip route`** are the commands for the same operations: `ip link add a type veth peer name b`, `ip link set b netns X`, `ip addr add 10.0.0.2/24 dev b`, `ip route add default via 10.0.0.1`. They are the manual equivalent of what a CNI plugin or the worker does programmatically.

**veth pair** is two virtual Ethernet devices joined back to back, so a frame sent into one comes out of the other. With the ends in different namespaces, it is the standard way to connect a namespace to the outside. Pods use one end as `eth0`. Each actor uses a pair between its runtime namespace (`eth0`) and its gateway namespace (`atside`).

**Linux bridge** is an in-kernel layer-2 switch. Bridge-style CNI plugins attach each Pod's host-side veth to a node bridge such as `cni0`. Actors do not use a bridge; their gateway namespace terminates traffic in atunnel.

**iptables / nftables** are the kernel's packet-filtering and NAT frameworks; nftables is the newer one, programmed with the `nft` command or netlink. Kubernetes uses them for Services (kube-proxy) and for CNI masquerading. Substrate's worker installs per-actor nftables tables that drop forwarding, reject link-local and non-TCP traffic, and `redirect` TCP to atunnel's port 15001.

**conntrack and `SO_ORIGINAL_DST`.** NAT state is kept in the connection-tracking table. A program that accepts a redirected connection can call `getsockopt(SOL_IP, SO_ORIGINAL_DST)` to learn the destination the client originally dialled. atunnel uses this to route actor egress ([original_dst_linux.go](https://github.com/agent-substrate/substrate/blob/v1.0.0/internal/linuxsys/original_dst_linux.go)).

**`sysctl` and `/proc/sys/net`.** Many network settings, such as `ip_forward`, `arp_notify` and `rp_filter`, are per network namespace and are set by writing files under `/proc/sys/net` while inside the namespace. CNI plugins and the worker both do this.

**Packet sockets (`AF_PACKET`).** These send and receive raw frames on an interface. gVisor's netstack, in sandbox networking mode, uses the namespace's interface this way, so the TCP/IP state lives in the Sentry rather than in the host kernel.

**Unix domain sockets** carry local RPC between processes on one host: the CRI socket, containerd shims' ttrpc sockets, atelet's worker sockets per Pod UID, `WorkerSupport` and the object-store plugin. They also carry file descriptors between processes (`SCM_RIGHTS`), which is how the gVisor gofer donates host files to the Sentry.

## Memory and files

**`mmap` / `munmap`** map files or anonymous memory into an address space. The Sentry maps its memory file into stub address spaces; restore maps image data back into it.

**`memfd_create`** creates an anonymous, memory-backed file with no path. gVisor uses one as the memory file that backs all application memory, which is what makes memory checkpointing a matter of saving one file's populated ranges.

**`fallocate` and `madvise`** reserve or punch holes in file space, and advise the kernel about memory usage (for example `MADV_DONTNEED` to release pages). A user-space kernel uses calls of this kind to manage its memory file. The exact set belongs to the runsc release.

**`userfaultfd` and `UFFDIO_COPY`.** These let a user-space handler service page faults for a registered memory region: faults arrive as messages on a file descriptor, and the handler supplies the page contents with `UFFDIO_COPY`. Cloud Hypervisor's OnDemand restore uses this to load guest memory lazily. Substrate's microVM path selects it only conditionally; its gVisor path does not use it.

**`sync_file_range`** starts or waits for writeback of a file range without flushing metadata or disk caches. The worker uses it to make checkpoint pages clean, and therefore reclaimable, quickly ([snapshotcache.go](https://github.com/agent-substrate/substrate/blob/v1.0.0/internal/snapshotcache/snapshotcache.go)).

**`fsync` / `fdatasync`** flush a file's data (and, for `fsync`, its metadata) to stable storage. etcd and PostgreSQL rely on them for commit durability. They are the durability primitives; `sync_file_range` is not.

**`cachestat`** reports how many of a file's pages are cached, dirty, under writeback, evicted or recently evicted. It was added in Linux 6.5. The worker polls it to know when checkpoint files no longer occupy dirty memory.

**`posix_fadvise(POSIX_FADV_DONTNEED)`** asks the kernel to drop clean cached pages of a file range. The worker uses it after checkpoint writeback and after background restore to avoid keeping redundant image pages.

**`lseek(SEEK_DATA / SEEK_HOLE)`** finds the next populated region or hole in a sparse file. atelet's sparse helpers use it to transfer only populated extents of memory images.

**`copy_file_range`** copies bytes between two files inside the kernel, letting filesystems share extents (reflink) or avoid copying through user space. atelet uses it when materializing sparse captures.

## Operator commands used in these chapters

**`kubectl`** is the Kubernetes API client; **`kubectl ate`** is Substrate's plugin speaking ateapi's gRPC API. **`crictl`** speaks CRI to containerd and shows Pod sandboxes, containers and images as the kubelet sees them. **`ctr`** speaks containerd's native API and shows content, snapshots and tasks. **`runc`** and **`runsc`** are the OCI runtimes. Running `runsc --root <dir> list` with the worker's per-actor state root lists the containers of one actor. **`nsenter`**, **`ip`**, **`nft`**, **`ss`** and **`findmnt`** inspect namespaces, networking, sockets and mounts. Under gVisor, `ss` and `ip route` see only the host side, because the actor's sockets live in the Sentry.
