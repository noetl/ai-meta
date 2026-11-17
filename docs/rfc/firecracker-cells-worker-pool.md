# RFC: worker pools as intercommunicating cells, with Firecracker microVMs as the isolation boundary

Status: **draft for review 2026-11-16. Nothing is built; no code, manifest or prod change.** Every claim carries a
label (below). No benchmark number in this document is new: every number is either quoted from a cited source with its
label, or listed in §11 as an open measurement.
Written 2026-11-16 against `main` of server `ebd3f30d` (v3.165.0), worker `cdb737f7` (v6.19.0), tools `ad03a84`
(v4.7.0), ehdb `210531d` (v0.15.1).

Owner prompt, verbatim: *"how to enhance noetl worker pool handing by introducing firecracker microvm and some concept
of distributed operating system especially Intercommunicating Cells."*

**Companion RFC:** [`interstate-runtime-bus.md`](interstate-runtime-bus.md) (ai-meta#586, PR #587). It uses the
cell and mailbox model defined here (§5.3) one level up: a *runtime* has an identity and mailboxes, and messages
cross between runtimes. A sender addresses another runtime's capability mailbox, never its cells; the receiving
server routes onto this RFC's subjects (interstate §3.3, §4). ⚠ Until both PRs merge, the cross-links resolve only
on their branches.

Related:
- `bot-fleets-vs-shared-account-vm.md` §7.1 (ai-meta PR #556; ⚠ not yet on `main`, read it on branch
  `docs/rfc-bot-fleets-vs-shared-vm`): isolation tiers
  T0–T3 and the credential capability model. This RFC is the design of T2/T3 and of the pool shape that hosts them.
- `latency-reduction-plan.md` (same PR and branch, Stages 0–5, issues #557–#562). This RFC must not undo any of it (§2.3).
- [`coroutines.md`](coroutines.md) (ai-meta#554): leaf units, join policies, cancellation. Cells are where a leaf unit
  runs, and a VM kill is the cancel point §5.2 of that RFC lacks.
- `ehdb-execution-partitioned-event-store.md` (ai-meta PR #355, branch `design/ehdb-execution-partitioned-store`; Stage 3 / #560): scoped history reads, the property
  that makes a cell's hydrate cost independent of log size.
- [`ehdb-topology-membership.md`](ehdb-topology-membership.md): D8 `RuntimeDataset` and the foca gossip decision. Cell
  discovery reuses it instead of inventing a registry.
- [`distributed-playbook-catalog.md`](distributed-playbook-catalog.md) (ai-meta#548): content addressing and execution
  pinning, extended here to the execution *environment*.
- [`agents/rules/execution-model.md`](../../agents/rules/execution-model.md),
  [`data-access-boundary.md`](../../agents/rules/data-access-boundary.md),
  [`self-sufficiency.md`](../../agents/rules/self-sufficiency.md): the constraints this design is measured against.

**Labels**
- **REAL**: in the code on `main` today, cited.
- **DEPLOYED**: read off prod (via the resource model or a cited prior RFC).
- **MEASURED**: observed, with date and environment, from a cited source.
- **GIVEN**: stated by an external source (Firecracker docs, GKE docs, Wikipedia), not verified by us.
- **TARGET**: proposed here.
- **NOT_YET_MEASURED**: a real question with no number. None is invented.

---

## 0. Summary

1. **Firecracker does not make steps faster.** Per-step cost is orchestration (~0.95 s per step, MEASURED prod
   2026-11-02, latency plan), and Stages 1–5 attack that. A microVM is an *isolation and lifecycle* primitive. Its value
   is a hardware-virtualized boundary per tenant, per execution or per untrusted tool, at a start cost that a Kubernetes
   Job cannot reach, plus snapshot-restore so a warm sandbox does not need a resident pod.
2. **So isolation is chosen per step, and the trusted fast path never enters a VM.** In-process kinds and WASM (T0/T1)
   stay in the worker process, where Stages 1 and 4 put them. Only T2 (untrusted native code: `python`, `shell`,
   `duckdb` with extensions, agent code execution) and T3 (session sandboxes) run in microVMs.
3. **The worker pod becomes a cell host**: the node kernel of a small distributed OS. It keeps its claim loop, local
   drive, `task_sequence` driver and WASM runtime, and gains a cell manager that runs a pool of jailed Firecracker
   microVMs restored from content-addressed snapshots. KEDA keeps scaling hosts; the cell manager places cells.
4. **The cell model.** The Intercommunicating Cells paper (Lee, 1962) is about associative, *unaddressed* storage cells,
   not message-passing actors (§5.1). The part that transfers is exactly what NoETL already does and should make a
   rule: work is never addressed to a worker; it is retrieved by attributes, and any qualifying cell is
   interchangeable. Mailboxes, supervision and failure containment come from the microkernel and supervision lineage,
   and are labelled as borrowed.
5. **Multi-runtime steps.** An ordered tool list can mix runtimes and jump between tools (`do: jump | retry | break`,
   REAL). Control flow stays on the host; each tool runs in the cell for its runtime profile; results pass by
   reference. A cell is a leaf executor and never sees control flow, so replay is unaffected.
6. **The hard blockers are platform, not code**: prod is GKE Autopilot, where nested VMs need privileged pods from a
   `WorkloadAllowlist` (GIVEN, §3.6), and the kind lane runs on a podman machine on macOS where `/dev/kvm` is not
   assumed. Phase F0 settles both before any code.

---

## 1. Problem: what pool-of-pods cannot do

### 1.1 The worker pool today (REAL / DEPLOYED)

| Property | Today | Source |
|---|---|---|
| Unit of compute | one worker process with `WORKER_MAX_CONCURRENT` slots, DEFAULT 4, as a `tokio::Semaphore` | `worker/src/config.rs:115`, coroutines RFC §2.1 |
| Pool | a worker claims only its subject `commands.<pool>.>` on the EHDB command bus | `worker/src/worker.rs`, bot-fleets §1.2 |
| Scaling | user pool KEDA 2–20 on `ehdb_feed_subject_lag`; system pool fixed 1 + 1 | DEPLOYED, bot-fleets §1.2 |
| Per-request routing | `NOETL_POOL_ROUTES` maps path prefixes to pools (auth pool isolation, #562) | REAL, `server/src/config/app.rs:180`, `handlers/execute.rs:132` |
| In-process kinds | `http`, `postgres`, `duckdb`, `rhai`, `agent`, `mcp` share the worker's address space | REAL, resource model `step_kinds` |
| Subprocess kinds | `python`, `shell` inherit the worker env; no `env_clear` in the tool crate | REAL, `tools/src/tools/python.rs:637-646`, `shell.rs:93-103`; `git grep env_clear` in tools = 0 hits |
| WASM | wasmtime with fuel, wall-clock and memory limits; one module at a time per process | REAL, `worker/src/plugin.rs:41-47`; mutex at `worker/src/executor/command.rs:163` |
| Pod boundary | only `kind: container`, as a Kubernetes Job; the slot is freed and a watcher calls back | REAL, `tools/src/tools/container.rs`, `worker/src/executor/command.rs:1430-1468` |
| Ordered tool list | `task_sequence` runs tools strictly in order with `continue / break / fail / jump / retry` | REAL, `tools/src/tools/task_sequence.rs:622-842` |
| Mid-run cancel | none in the worker | REAL, coroutines RFC §2.1 |

### 1.2 The limits

| Limit | Why pods cannot fix it | What would |
|---|---|---|
| **Isolation granularity.** The boundary is the pod, and every tenant's steps on a pool share pods. A python step routed to the system pool can read `NOETL_INTERNAL_API_TOKEN` (bot-fleets §2.1). | A pod per step is a Kubernetes Job; its start cost is a scheduler round trip and an image pull, and on Autopilot possibly a node (~60–90 s, MEASURED prod, latency plan Stage 5). | A boundary that is created inside an already-running pod. |
| **Noisy neighbour.** A `duckdb` query spends the pod's memory limit for every step on the pod (resource model). | cgroups exist per container, not per step inside one. | A per-cell memory and vCPU envelope. |
| **Per-step resource bounding.** Only WASM steps and container Jobs have bounds. A slot is a count, not a size: four 2 GiB duckdb steps and four `http` calls cost the same "4". | Requests and limits are per pod. | Admission by resource envelope instead of slot count (§3.5). |
| **Warm-pool cost.** Stage 5 keeps a warm floor ≥ 2 on interactive pools. A sandboxed tier with its own warm floor per tenant or runtime would multiply that by tenants. | A warm pod is a resident, billed pod. | A snapshot on disk: warm in latency terms, ~0 resident cost (§3.4). NOT_YET_MEASURED. |
| **Cancel and timeout.** No mid-run cancel; no per-command timeout (coroutines §2.1). Cooperative cancel points (coroutines §5.2) cannot interrupt a hung native library call. | Killing the pod kills every slot on it. | Killing one VM kills one unit. |
| **Runtime heterogeneity.** A step's tool list can need python 3.12, a duckdb build with extensions and a node tool, all in one image today. | One image per pool; the image is the union of runtimes. | A runtime profile per cell (§4). |

### 1.3 What this RFC does not try to fix

- Per-step orchestration overhead. That is the latency plan. §2.3 states how this design avoids making it worse.
- The credential model itself. That is bot-fleets §7.1.4; this RFC says where its per-command keys live.
- Server or EHDB isolation. Only workers become cells.

---

## 2. Constraints and non-goals

### 2.1 Constraints (from the rules)

- **Execution model.** Workers are stateless atomic blocks; state lives in the event log and the shared cache. A cell
  must hold nothing that cannot be rebuilt from EHDB.
- **Data access boundary.** Only the server touches `noetl.*`. A guest inside a microVM never talks to the server; it
  talks to its host over vsock, and the host calls the server API (§3.3). This also keeps the internal API token out of
  every guest.
- **Self-sufficiency.** No external service. Firecracker is a binary and a library-shaped dependency, not a running
  service with its own quorum. The VMM, jailer and any SDK are used as-is; nothing in the VMM or jailer is hand-rolled.
- **Secrets.** Business credentials stay in the keychain, resolved per step, sealed per command (bot-fleets §7.1.4).
  Never baked into a guest image or a snapshot.
- **Event log is the truth.** Replay must reproduce state without re-running a cell.

### 2.2 Non-goals

- Replacing KEDA or Kubernetes. Hosts remain pods.
- A microVM per step for in-process kinds.
- MicroVMs at the edge. The edge runs compiled WASM (kuksin.us, #548 phase 3), unchanged.
- A new consensus, membership or discovery service (D8 + foca already decided).

### 2.3 Latency invariants (must hold, checked in every phase)

1. With every flag off, behaviour is byte-identical.
2. A step whose tier is T0/T1, or an in-process kind on a trusted playbook, never crosses a vsock boundary.
3. Stage 1 local drive and Stage 4 fused segments run on the host. A fused segment ends where a step needs a T2 cell,
   exactly as it ends today at a pool boundary.
4. A T2 step must not be slower than the same step as a `kind: container` Job, which is its current only sandboxed path.
   The comparison is NOT_YET_MEASURED (§11, M1–M3).

---

## 3. Firecracker integration (TARGET)

### 3.1 Granularity: what one microVM is

| Option | Boundary between | Start cost per unit | Fits | Verdict |
|---|---|---|---|---|
| **A. microVM per worker process** | worker processes | once per pod | nothing a pod does not already give | rejected: the pod boundary again, plus a VM |
| **B. microVM per execution (lease)** | executions | once per execution, amortised across its T2 steps | multi-step untrusted work, agent code execution, T3 sessions | **yes, default for T2** |
| **C. microVM per step** | steps of one execution | once per T2 step | one-off untrusted steps, strict per-step isolation | yes, opt-in (`isolation.scope: step`) |
| **D. microVM per tool in a tool list** | tools of one step | once per tool | heterogeneous runtimes (§4) | only where the runtime profile changes |

The unit of scheduling is a **lease**: a cell bound to (principal, execution, runtime profile, resource envelope) until
its scope ends. B is the default because it pays the restore once per execution while still separating executions and
tenants. A lease never spans principals.

### 3.2 Boot, restore and warm pools

- **GIVEN** (Firecracker `SPECIFICATION.md`): ≤ 125 ms from `InstanceStart` to guest `/sbin/init`, with a minimal
  kernel and rootfs and the serial console off; VMM thread memory overhead ≤ 5 MiB for 1 vCPU / 128 MiB; VMM up to
  API-socket in ≤ 8 CPU ms. Measured by the project on `m5d.metal` / `m6g.metal` hosts.
- Those numbers end at `/sbin/init`. A useful python cell also needs the interpreter and its imports loaded, which is
  the cost a snapshot removes. Restore maps guest memory privately and loads it on demand (GIVEN, snapshot docs); no
  restore latency figure is given by the project. NOT_YET_MEASURED (M2).
- **None of the GIVEN numbers applies to nested virtualization on GKE.** GKE's page warns nested workloads may see
  reduced performance (GIVEN). Every boot and restore number must be re-measured on the target node shape (M1, M2).

Warm-start ladder, cheapest first:

1. **Live idle cell** of the right profile already restored on this host: lease it. Costs resident memory.
2. **Snapshot restore** of the profile's golden snapshot: the default path.
3. **Cold boot** from kernel + rootfs: only to build a snapshot, or when no snapshot exists.

The cell manager keeps a per-profile target of live idle cells (TARGET default 0; a latency-sensitive profile may set
1). This is the microVM analogue of the Stage 5 warm floor, priced in host memory instead of pods.

### 3.3 Host, guest and the jailer

```
cell-host pod (KEDA-scaled, privileged, /dev/kvm)
├── noetl-worker            claim loop · local drive (#558) · task_sequence driver · WASM (T0/T1) · server HTTP client
├── cell manager            lease table · admission (§3.5) · snapshot cache (by digest) · supervisor (§5.4)
└── per cell:  jailer ─▶ firecracker (one process per microVM)
                         chroot · pid/net/mount namespaces · cgroup v2 · seccomp · unprivileged uid   (GIVEN: jailer)
                         virtio-net (tap in a per-cell netns) · virtio-block (rootfs ro + scratch) · vsock
                         └── guest: minimal kernel + runtime profile rootfs + noetl-cell agent
                                    vsock RPC only: run_tool · cancel · health · post_restore
```

- **The guest has no network path to the server and no server token.** Tool inputs arrive over vsock with resolved
  `{{ }}` values and sealed credentials (§3.7); outputs go back over vsock. The host emits `call.done` /
  `command.completed`, as today.
- **Egress** is per cell: a tap device in a cell netns, default deny, allowlist from the playbook's capability manifest
  (bot-fleets §7.1.2), enforced by the host with nftables. Rate limiters on virtio devices bound bandwidth and ops
  (GIVEN).
- **Large data** goes by result-store reference. The host fetches and passes bytes over vsock, or attaches a read-only
  block device for large inputs. Which is cheaper is NOT_YET_MEASURED (M5).
- **Build, not invent.** Candidates to evaluate rather than write: firecracker-containerd, Kata Containers with the
  Firecracker VMM, the Firecracker Go SDK, and maintained Rust crates for the API socket. The cell manager's lease
  table and admission are ours; the VMM, jailer and image tooling are not.

### 3.4 Snapshots as content-addressed artifacts

- A **runtime profile** is a declared environment: guest kernel, rootfs (built from an OCI image; an OCI image is not a
  complete guest by itself, GIVEN), the `noetl-cell` agent version, and an init script that imports the profile's
  libraries. Its digest is the hash of all four.
- A **golden snapshot** is taken after the guest kernel has finished booting and the init script has run (the project
  warns that snapshots taken very early in boot may crash on resume, GIVEN). Its digest covers the memory file and
  `vmstate`.
- Snapshots are stored by digest in the object store next to catalog artifacts (#548), and **verified by digest before
  every restore**, because Firecracker treats snapshot files as trusted and leaves authentication to the integrator
  (GIVEN).
- Snapshots must resume on identical hardware and software (GIVEN). The snapshot key is therefore
  (profile digest, host CPU template, host kernel, Firecracker version). A host with no matching snapshot builds one on
  first use and publishes it.

**The uniqueness hazard, which bites this design directly.** Restoring one snapshot into several VMs duplicates
identifiers, random state and cryptographic material; the project calls loading one snapshot into several VMs
insecure. Linux ≥ 5.18 reseeds the kernel PRNG via VMGenID on resume, but application state is still duplicated
(GIVEN). Sealed delivery encrypts credentials to a key; a key that existed when the snapshot was taken would be shared
by every restored cell. Rules (TARGET):

1. No key, token, cell id or seed is generated before the snapshot point.
2. `post_restore` (vsock) must complete before a cell is leasable: reseed userspace RNGs, generate the per-lease keypair,
   correct the wall clock (it resumes at snapshot time, GIVEN), report the new public key. A cell that has not reported
   is not leasable. Fail closed.
3. Whether many restores of one golden snapshot are acceptable with rules 1–2, or whether each snapshot is restored once
   (which breaks the warm economics), is **open question Q3**.

### 3.5 Resource envelopes as first-class scheduling

- A step may declare an envelope; a runtime profile declares a default:

  ```yaml
  - step: score
    isolation:
      tier: T2              # T0 | T1 | T2 | T3; default from playbook trust policy (bot-fleets §7.1.2)
      profile: python-3.12-ds
      scope: execution      # execution (default) | step | tool
      vcpu: 1
      mem_mib: 1024
      timeout_s: 60         # enforced by the host killing the VM
    tool:
      kind: python
      code: ...
  ```

- **Admission, not slots.** On a cell pool the semaphore becomes a budget: a host claims a command only if the sum of
  live envelopes plus the new one fits its allocatable vCPU and memory (minus a host reserve). A pull loop that cannot
  admit does not claim, so the command stays on the bus for another host, and the bus lag still drives KEDA. In-process
  pools keep slots unchanged.
- **Overcommit policy** (vCPU overcommit yes or no, memory never) is open question Q5.

### 3.6 Where it sits relative to KEDA and GKE

- Two-level scheduling: **KEDA sizes hosts** on subject lag, unchanged; **the cell manager places leases** on a host.
  Routing to cell pools uses per-profile subjects (§5.2) and `NOETL_POOL_ROUTES`-style rules, so a T2 step lands only on
  a cell pool.
- **GKE (GIVEN, docs fetched 2026-11-16):** nested virtualization is supported on Standard node pools created with
  `--enable-nested-virtualization` (not on existing pools), and on Autopilot only through a ComputeClass on GKE
  ≥ 1.37.0-gke.4713000. Pods using nested VMs need `privileged: true`; Autopilot allows that only for allowlisted
  workloads (`WorkloadAllowlist`). Only some machine series support it (examples given: C3, C4, C4D, N4). The org policy
  must not enforce "Disable VM nested virtualization". Third-party software such as Kata is outside Google's support.
- Consequence: a cell pool is a separate node class with its own cost, and the privileged host pod is a larger trust
  surface than today's worker pod (risk R2).
- **Alternative to compare in F0 (Option K):** Kata Containers with Firecracker via a `RuntimeClass`, one VM per pod.
  It is Kubernetes-native and needs no cell manager, but keeps the pod-scheduling start cost per sandbox, so it fits T3
  sessions and long T2 steps better than short ones. Option F (this section) owns more code and gets sub-pod leases.
  The F0 measurement decides; this RFC does not presume.

### 3.7 Credentials inside a cell

- The host resolves keychain references through the server, as today, and passes them to the cell sealed to the cell's
  per-lease key from `post_restore`. That is bot-fleets §7.1.4's "per-command ephemeral key", with the key living in
  exactly one VM.
- Subprocess env inside the guest is built from an allowlist; the guest has no worker env to inherit.
- When the lease ends the VM is destroyed, never returned to the idle set (§5.4). A cell is reused only within its
  lease.

---

## 4. Several tools in one step, different runtimes, conditional jumps (TARGET)

The caveat: one step's ordered tool list may need different runtimes, and `task_sequence` moves between tools with
`do: continue | break | fail | jump | retry` (REAL, `tools/src/tools/task_sequence.rs:622-842`). A single "microVM per
step" therefore either needs one image with every runtime or splits the step.

**Decision proposed: control flow on the host, execution in cells.**

```
host: task_sequence driver (unchanged code path)
  tool 1  http            → in-process (T1)                      result → ctx
  tool 2  python          → cell[python-3.12-ds]  over vsock     result → ctx   do: jump → tool 4 if …
  tool 3  duckdb          → cell[duckdb-ext]                     (skipped by the jump)
  tool 4  python          → same cell[python-3.12-ds], same lease
  evaluate step `next`    → host (local drive, #558)
```

- The driver evaluates every `do:` verb and every template on the host, after each tool result. A cell receives one
  fully-rendered tool invocation and returns one result. It never sees the step graph, the tool list or a condition.
- A lease is per (execution, profile), so a jump back to a python tool reuses the same cell; a retry reuses it unless
  the failure class was `cell_crashed` (§5.4), in which case it gets a fresh cell.
- Values move between tools through the host's context, as they do today. A large result goes by result-store
  reference (M5).
- **Profile merging.** If a tool list's runtimes are known together (a "profile set" in the playbook), the build may
  produce one merged profile and run the whole list in one cell, saving vsock hops and restores. That is an
  optimisation over a correct split, not a different model.
- **Where WASM fits.** T0/T1 WASM runs on the host under wasmtime, which already bounds fuel, time and memory. WASM goes
  inside a microVM only when it is untrusted *and* needs host imports beyond the capability manifest, which should be
  rare. Fused segments (#561) are host-side, end at the first T2 step, and resume after it through local drive.
- This is consistent with the coroutines decision (§11.1 there): a unit is a leaf, branching stays in the graph. A
  coroutine group's units may each run in their own cell; the join stays on the server.

---

## 5. The cell model (TARGET)

### 5.1 What the Intercommunicating Cells idea actually says

The Wikipedia article on distributed operating systems (fetched 2026-11-16) cites C. Y. Lee, "Intercommunicating
cells, basis for a distributed logic computer", 1962 Fall Joint Computer Conference, as an early effort at abstracting
memory access (GIVEN):

- A cell stores a name and a set of parameters. Retrieval is either **direct** (name → parameters) or **cross**
  (parameter subset → every name that holds it).
- **Addressing is treated as a wasteful level of indirection.** Cells are logically indistinguishable, so the system is
  easy to extend.
- Retrieval time is mostly constant, independent of memory size or fill, and the operation is atomic and exclusive.
- System logic is distributed across the cell associations.

The article does **not** describe message passing, mailboxes, supervision or autonomy for these cells. Those come from
other parts of the same lineage the article covers: a minimal kernel per node providing process, communication and I/O,
with policy in higher-level components outside the kernel; and transparency (location, migration, replication,
failure). Supervision trees are borrowed from actor systems and are not in the cited article. Each borrowing is named
below.

### 5.2 How the ideas map onto NoETL

| Idea | Source | NoETL today | TARGET |
|---|---|---|---|
| **No addressing** | Lee | REAL: a command is published to a subject; any worker on that pool claims it. Nothing addresses a worker. | Make it a rule. A command names *what it needs*, never *who runs it*. |
| **Cross-retrieval by parameters** | Lee | a pool name is a single coarse parameter | Subjects carry capability attributes: `commands.<pool>.<tier>.<profile>.>`. A host subscribes to the profiles it has snapshots for. Generalising to arbitrary attribute predicates is Q6. |
| **Indistinguishable cells** | Lee | REAL: workers are stateless; any worker can run any step on its pool | Invariant: a cell's only durable outputs are events and result-store objects, both emitted through the host. |
| **Constant-time retrieval, independent of size** | Lee | not true: chain reads filter every record (#355 §1.3) | #355 E2–E4 (per-execution index). A cell's hydrate cost must not grow with total log size. This RFC depends on it rather than repeating it. |
| **Kernel per node, policy outside** | DOS lineage (microkernel) | the worker mixes mechanism and some policy | The cell host is the node kernel: lease, admission, IPC (vsock), I/O. Policy (tiers, quotas, routing, trust) stays on the server. |
| **Transparency** | DOS lineage | a playbook does not know which worker ran a step | Preserved: a playbook declares `isolation`, never a host. Failure transparency is bounded: a `cell_crashed` is visible in events, by design. |
| **Supervision** | borrowed (actor systems) | heartbeats per worker; orphan sweep (off by default) | §5.4. |

### 5.3 A cell, defined

A **cell** is (isolation boundary, runtime profile, resource envelope, mailbox, identity):

- **Boundary:** a microVM (T2/T3) or a WASM instance on the host (T0/T1). In-process kinds are cells of the trivial
  kind: the host itself.
- **Mailbox:** the capability subject it claims from. A **lease-affine** mailbox, `cell.<cell_id>`, exists only for the
  continuation case Stage 1 already has (the server hands back an already-claimed command to the same worker). The
  affine mailbox is a hint: if the cell is gone, the command falls back to the capability subject. It is never the only
  route.
- **Identity:** `cell_id`, `generation` (incremented on every restore), `host_id`, `profile_digest`,
  `snapshot_digest`, `principal`, `execution_id` of the lease.

**Discovery** reuses D8 `RuntimeDataset` (topology RFC §0: implemented, unused) for hosts and their profile sets, and
foca gossip for host liveness, both as already decided. Individual cells are not registered cluster-wide: they live
seconds to minutes, and their host is the authority. A cell becomes visible in events (§5.5), which is what replay and
audit need. Registration goes host → server API, never guest → anything.

Cross-runtime addressing (cluster ↔ daemon ↔ CLI) is defined in the companion
[`interstate-runtime-bus.md`](interstate-runtime-bus.md): `noetl://<ni>/cells/<cell_id>` is valid only inside `<ni>`, and
another runtime reaches these cells only through that runtime's capability mailbox.

**ehgraph** can render cell topology (host → cells → profile, principal) for operators and agents as a read model fed
from D8 and events. It is not authoritative: it is a single-primary MVP, and a topology view that can disagree with the
hosts is a representation (see `representation-drift.md`).

### 5.4 Supervision and failure containment

Hierarchy: **server** (policy, execution state) → **cell host** (supervisor) → **cell**.

| Failure | Detected by | Contained to | Recovery |
|---|---|---|---|
| tool error inside a cell | tool result | the tool | normal `do:` / `retry` handling on the host |
| guest crash, OOM, VM exit | VM process exit, vsock EOF | one cell, one lease | host emits failure class `cell_crashed`; the VM is discarded, never reused; a retry gets a fresh restore |
| timeout | host timer from `isolation.timeout_s` | one cell | VM killed; class `cell_timeout` |
| cancel (coroutine `race`/`any` loser, owner timeout, execution cancel) | server cancel event reaching the host | one cell | VM killed. This is a hard cancel point for coroutines §5.2, which today has none for native code. Bound on time-to-stop is NOT_YET_MEASURED (M6). |
| snapshot digest mismatch | pre-restore verification | one restore | refuse; rebuild; class `cell_snapshot_invalid`; alert |
| host crash | heartbeat / lease expiry | the host's leases | today's path: orphan sweep. ⚠ The bus acks at claim, so there is no redelivery (coroutines §2.1); a cell pool inherits that gap until it is fixed there. |

Restart strategy is one-for-one: one cell's death never touches its siblings, unlike a pod restart today. Because no
cell is ever returned to the idle set after a lease, a compromised guest cannot carry state into the next tenant.

### 5.5 Replayability

- A cell is a leaf. Its non-determinism (tool output, timing) is recorded in `call.done` as today. Replay reads results;
  it never re-runs a cell.
- The environment becomes part of the record: `command.claimed` / `call.done` gain `cell_id`, `generation`,
  `profile_digest`, `snapshot_digest`, `tier`, `envelope` (behind `NOETL_CELL_METADATA`). With #548's playbook pin,
  that answers "which code, in which environment, produced this result".
- Re-execution (a rerun from a point, not a replay) may request the same `profile_digest`, which is reproducible from
  the profile definition, not from a host.

---

## 6. Proposed architecture

```
 gateway ──▶ server  (orchestrate-core · policy: tiers, trust, quotas · NOETL_POOL_ROUTES · advance API #558)
               │  publishes commands by capability, never by address
               ▼
        EHDB command bus  ── commands.<pool>.>                          (unchanged pools)
                          ── commands.<cellpool>.T2.<profile>.>          (new, flag-gated)
               │
   ┌───────────┴───────────────┐
   ▼                           ▼
 worker pods (today)        cell-host pods (new node class, nested-virt, privileged)
 T0/T1 + in-process         noetl-worker + cell manager
 local drive, fused         ├─ T0/T1 + in-process, local drive, fused segments (same as left)
 segments                   ├─ admission by envelope
                            ├─ snapshot cache by digest ◀── object store (next to catalog artifacts)
                            └─ cells: jailer → firecracker → guest (noetl-cell agent, vsock only)
               │
               ▼
        server API ◀── host only: claim, events, result refs, keychain (sealed per lease)
        EHDB event log + D8 RuntimeDataset ──▶ ehgraph (read model)
```

---

## 7. Migration path (TARGET; every flag OFF by default)

Same rules as the latency plan: one feature per PR; flag off is byte-identical; accepted only on a before/after
measurement from the Stage 0b harness (n ≥ 10 per arm, p50 and p95); validation matrix includes the 10-hop probe,
concierge, a planner turn and the auth/login multi-hop with its 15 s budget. Nothing reaches prod without the owner.

| Phase | What | Repos | Flag | Depends on | Verify |
|---|---|---|---|---|---|
| **F0** | Decide the platform. Measure M1–M4 on (a) a GKE Standard nested-virt node pool in a non-prod project, (b) a KVM-capable Linux dev host. Compare Option F vs Option K (§3.6). Check whether the prod Autopilot cluster can get a ComputeClass + `WorkloadAllowlist`. | ai-meta (report) | none | — | a written result with denominators and dates; go/no-go |
| **F1** | `CellBackend` trait in the worker with today's backends only (in-process, subprocess, WASM, container Job). Events carry cell metadata. | worker, tools | `NOETL_CELL_METADATA` | — | event equivalence with flag off; metadata present with flag on |
| **F2** | Hardening independent of VMs: `env_clear` + allowlist for `python`/`shell` (bot-fleets §7.1.3). | tools | `NOETL_SUBPROCESS_ENV_ALLOWLIST` | — | a python step cannot read the internal token |
| **F3** | Firecracker backend, cold boot only, one profile (`python-3.12`), scope `step`, on a dedicated cell pool. `noetl-cell` agent; vsock RPC; jailer; default-deny egress. | worker, new `noetl-cell` crate (in worker repo), ops | `NOETL_CELL_BACKEND=firecracker` | F0 go, F1 | the validation matrix unaffected (no T2 steps in it); a T2 python step correct; vs `kind: container` latency (§2.3.4) |
| **F4** | Runtime profiles + golden snapshots by digest; `post_restore` contract; scope `execution` leases. | worker, ops (image build) | `NOETL_CELL_SNAPSHOT` | F3, Q3 answered | uniqueness test: two restores of one snapshot hold different keys and RNG output; restore vs cold boot (M2) |
| **F5** | Admission by envelope on cell pools. | worker | `NOETL_CELL_ADMISSION` | F3 | over-subscription test; no claim that cannot be admitted; KEDA still scales on lag |
| **F6** | Capability subjects `commands.<cellpool>.T2.<profile>.>`; server routes T2 steps there; host profile sets in D8. | server, worker | `NOETL_CELL_ROUTING` | F4; D8 exercised (topology RFC §6) | a T2 step never lands on a non-cell pool; a T0 step never lands in a cell |
| **F7** | Cancel and timeout as VM kill; wire to coroutines stage 1 cancel propagation. | worker, server | `NOETL_CELL_HARD_CANCEL` | F3; coroutines stage 1 | time-to-stop distribution (M6); losers of a `race` stop |
| **F8** | Split heterogeneous tool lists across cells (§4); optional merged profiles. | tools (`task_sequence` dispatch hook), worker | `NOETL_CELL_SPLIT_SEQUENCE` | F4 | jump / retry / break semantics identical to flag off on a mixed-runtime fixture |
| **F9** | T3 session sandboxes (bot-fleets §7.4) on the same cell manager, with persistent scratch snapshotted between sessions. | worker, ops | `NOETL_CELL_SESSIONS` | F4 | suspend/resume round trip |
| **F10** | Prod. Owner decision. | ops | — | all above | the prod-roll smoke (e2e + travel planner + ranch concierge) before and after |

⚠ **Kind-first does not straightforwardly apply.** `deployment-validation.md` requires kind validation before GKE. The
kind cluster runs in a podman machine on macOS; whether that VM exposes `/dev/kvm` to a kind node is unverified and
should be assumed false. F0 must either establish a KVM-capable kind lane (kind on a Linux host with KVM) or the owner
must approve a non-prod GKE nested-virt pool as the validation lane for F3+ only. F1 and F2 validate on today's kind.

---

## 8. Alternatives considered

| Alternative | Why not (or not yet) |
|---|---|
| gVisor (`RuntimeClass` / GKE Sandbox) | Supported on Autopilot without nested virtualization and is the cheapest step from today. Still a pod per sandbox, so pod start cost per unit, and a user-space kernel rather than a hardware boundary. A strong candidate for T2 if F0 finds Firecracker unavailable on prod; F0 should measure it alongside. |
| Kata + Firecracker `RuntimeClass` (Option K) | §3.6. Pod-per-VM; less code; per-unit pod scheduling. |
| WASM for everything | Already the T0/T1 answer. Cannot host CPython with native extensions, duckdb extensions or arbitrary shell. |
| More, smaller pods per tenant | Multiplies warm-floor cost by tenants; does not bound per step. |
| A microVM per worker process | §3.1 A: the pod boundary again. |

---

## 9. Risks

| # | Risk | Mitigation |
|---|---|---|
| R1 | **Latency regression** from a vsock hop and a restore on a path that did not need isolation. | §2.3 invariants; tier chosen per step; T0/T1 never in a VM; measured per phase. |
| R2 | **Privileged host pods** with `/dev/kvm` are a larger trust surface than today's worker pod. | Jailer per VM; host runs no tenant code; guests have no server token; minimal host image. Accepting the privileged pod is an owner decision. |
| R3 | **Snapshot uniqueness** leaks keys or RNG state across cells. | §3.4 rules 1–2, fail closed; Q3. |
| R4 | **Nested-virt performance** is unknown on GKE and may erase the start-cost advantage. | F0 measures before any code. |
| R5 | **Operational load**: guest kernels, rootfs images and Firecracker itself need patching; snapshots are invalidated by host changes. | Profiles and snapshots are content-addressed and rebuilt by CI; snapshot key includes host kernel and Firecracker version. |
| R6 | **A cell registry that drifts** from the hosts. | Cells are not registered cluster-wide; the host is the authority; ehgraph is a read model. |
| R7 | **No redelivery after claim** (existing gap) is felt more on a pool where crashes are now contained and expected. | Inherit the coroutines/orphan-sweep fix; do not paper over it in the cell layer. |
| R8 | **Validation lane** does not exist in kind. | F0 decides; §7 note. |
| R9 | **Cost**: a nested-virt node class next to the existing pools. | Cell pools scale to zero when no T2 work is queued (Stage 5 cost-pool shape); NOT_YET_MEASURED (M7). |

---

## 10. Env flags (TARGET; all off by default)

| Flag | Component | Effect |
|---|---|---|
| `NOETL_CELL_METADATA` | worker | add cell identity fields to `command.claimed` / `call.done` |
| `NOETL_SUBPROCESS_ENV_ALLOWLIST` | tools | build `python` / `shell` env from an allowlist |
| `NOETL_CELL_BACKEND` | worker | `inprocess` (default) or `firecracker` |
| `NOETL_CELL_SNAPSHOT` | worker | restore from golden snapshots instead of cold boot |
| `NOETL_CELL_ADMISSION` | worker | admit by resource envelope instead of slot count |
| `NOETL_CELL_ROUTING` | server, worker | publish and claim T2 work on capability subjects |
| `NOETL_CELL_HARD_CANCEL` | worker | cancel and timeout by VM kill |
| `NOETL_CELL_SPLIT_SEQUENCE` | tools, worker | dispatch tools of one list to per-profile cells |
| `NOETL_CELL_SESSIONS` | worker | T3 session sandboxes |

Each lands with its row on the worker / server / tools `deployment-specification` wiki page in the same PR (wiki Rule 2a).

---

## 11. Open questions and measurements

### 11.1 Decisions for the owner

- **Q1.** Is a privileged, nested-virt host pod acceptable on prod at all (Autopilot `WorkloadAllowlist`, or a Standard
  node pool)? If not, T2 is gVisor and this RFC reduces to the cell model (§5) plus gVisor pods.
- **Q2.** Option F (in-pod cell manager) vs Option K (Kata `RuntimeClass`): decided by F0's numbers.
- **Q3.** May one golden snapshot be restored into many cells, given §3.4 rules 1–2? If not, what replaces it?
- **Q4.** Default `isolation.scope`: `execution` (proposed) or `step`?
- **Q5.** vCPU overcommit on cell hosts: allowed, and by how much? Memory overcommit is proposed as never.
- **Q6.** Capability subjects (fixed attribute order) vs a general attribute predicate on claim. The first fits the
  existing bus; the second is closer to Lee's cross-retrieval and needs a bus change.
- **Q7.** Which validation lane replaces kind for F3+ (§7 note)?
- **Q8.** Trust policy: which playbooks are T2 by default (untrusted tenant code only, or every `python`/`shell`)?

### 11.2 Measurements (NOT_YET_MEASURED; none invented)

| # | Measurement | Where |
|---|---|---|
| M1 | Firecracker cold boot to agent-ready, per profile, under nested virtualization | GKE nested-virt pool; KVM dev host |
| M2 | Snapshot restore to `post_restore` done, per profile and memory size | same |
| M3 | `kind: container` Job: issue → tool start, today (the T2 baseline) | kind and prod |
| M4 | gVisor pod: issue → tool start | non-prod GKE |
| M5 | vsock vs block-device transfer for 1 KiB / 1 MiB / 100 MiB inputs | KVM host |
| M6 | cancel → VM gone, distribution | KVM host |
| M7 | node-class cost per hour vs warm pod floor (owner supplies prices; this doc invents none) | — |
| M8 | per-cell host memory overhead including jailer, at 10 / 50 / 100 live cells | KVM host |

---

## 12. Linked issues

- Tracking: [noetl/ai-meta#584](https://github.com/noetl/ai-meta/issues/584).
- Companion: [noetl/ai-meta#586](https://github.com/noetl/ai-meta/issues/586) /
  [`interstate-runtime-bus.md`](interstate-runtime-bus.md) (PR #587).
- Composes with #554 (coroutines), #558–#562 (latency plan), #560 / PR #355 (EHDB substrate), #548 (catalog pinning),
  PR #556 (bot-fleets §7.1, §7.4).
