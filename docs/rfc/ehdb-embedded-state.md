# EHDB as embedded state, not a networked service

**Status: analysis. Nothing here is built, and nothing touches prod.**

The proposal is to run EHDB as NoETL's *internal* storage — event log, cache,
projections — called by the API server directly, in the RocksDB-inside-Flink
shape: state is a projection over an event log, snapshotted, owned per shard.

Today it runs as a separate networked service: a writer StatefulSet, an HTTP
relay through a ClusterIP in front of a single pod, and a remote tier. This
document asks how far the code already supports the first shape, and what the
move would cost.

Every claim below is grounded in the code as of `ehdb@49fdefc`,
`server@6f23a58`, and prod as observed 2026-09-08. Where I could not verify
something, I say so.

---

## 1. How far is EHDB already embeddable?

**Much further than the deployment suggests. The gap is one seam.**

### It is already a library workspace

| | |
| :-- | :-- |
| crates in the workspace | **11** |
| crates that are libraries | **11** |
| binaries in the whole workspace | **1** (`ehdb-reference`) |

There is no EHDB server binary. The thing running as `noetl-cmdbus-writer` in
prod is **the `noetl-worker` binary in writer mode** — NoETL's own worker,
linking the EHDB crates and exposing HTTP faces on :9100–:9110. The "service" is
not a separate product; it is our own process wrapping a library.

### Every engine has an in-process constructor

```rust
// ehdb-l0/src/command_queue.rs:130, blob.rs:108, projection.rs:87
pub fn open(config: L0Config, substrate: Arc<dyn DurableSubstrate>) -> Result<Self>
pub fn cold_load(config: L0Config, substrate: Arc<dyn DurableSubstrate>) -> Result<Self>
```

`DurableSubstrate` is the storage seam — the RocksDB-`Env` analogue — with
`LocalFsSubstrate` and `InMemorySubstrate` already implemented. Nothing about
opening an engine requires a network, a port, or a second process.

### The API is 100% synchronous

| | count |
| :-- | --: |
| `pub async fn` in `ehdb-l0` | **0** |
| sync `pub fn` in `ehdb-l0` | **236** |

This matters more than it looks, and §3 turns on it.

### The server links the crates and never opens an engine

`repos/server/Cargo.toml` depends on `ehdb-l0` and `ehdb-feed`. But:

```rust
// the ONLY use of the engine type in the server:
use ehdb_l0::{D1EventLog, EventRecord};                 // command_bus.rs:37
router: Mutex<Option<Arc<PublishRouter<D1EventLog>>>>,  // :160
PublishRouter::<D1EventLog>::connect(shard_count, addrs) // :462
```

`grep` for any engine construction in the server returns **nothing**.
`D1EventLog` is a *type parameter*, and `PublishRouter` holds
`_marker: PhantomData<fn() -> D>` — it never touches a local engine. Its only
constructor is `connect(shard_count, addrs)` over TCP.

### The quantified gap

> **The server is one constructor away from in-process storage.**

Everything under `PublishRouter` is already in-process-capable. What is missing
is a local sibling to `PublishRouter::connect` — a router that dispatches to an
owned `L0Engine` instead of a `PipelinedPublishClient`. The trait shape is
already there (`D: Dataset`); the network client is one implementation of a
boundary that currently has only one implementation.

That is a genuinely small seam. **What is not small is everything built on the
assumption that the boundary is remote**: the mirror, the parity comparator, the
tier-service address configuration, the relay retry logic, the writer's HTTP
faces. Those are the cost, not the engine.

---

## 2. Event-log-as-truth and snapshots, in the code today

### The projection is already the fold, and it is already snapshotted

`ehdb-l0/src/projection.rs` describes itself:

> an **append-only log of projection snapshots** … the current state of an
> execution being the **latest** snapshot — a fold

Sort key `proj_seq`, partitioned by execution. `record_state` appends,
`get_state` reads the latest, `list_executions` enumerates. This *is* the model
being proposed. It is not something to build.

### There are two distinct snapshot layers, and conflating them would be a mistake

| layer | what it snapshots | analogue |
| :-- | :-- | :-- |
| **manifest** (`manifest_snapshot()`, `manifest_retain`) | which *parts* exist — storage layout | RocksDB MANIFEST / SST set |
| **projection** (`ProjectionOp`, `proj_seq`) | the *state* folded from events | Flink checkpoint |

The manifest is the thing that grew quadratically and filled the writer's PVC on
2026-09-01. It is bookkeeping about files, not state.

### Is "restore snapshot + replay tail" achievable now?

**The primitives exist; the wiring does not.**

- `cold_load` / `cold_load_replicated` are the restore half, in code.
- The fold is in code and is what the parity work has been exercising.
- **Missing:** nothing drives *restore-then-replay-tail* for the server. The
  recovery path that exists folds from **Postgres**, not from the tier — which
  is exactly what [#307](https://github.com/noetl/ai-meta/issues/307) recorded
  as "coverage ~0 by construction": the in-path verdict cannot see
  tier-vs-Postgres divergence because it never reads the tier.
- **Missing:** a durable per-shard *cursor* (last applied event) that survives
  restart, so "the tail" has a defined start. I did not find one; I may have
  missed it, and this should be confirmed before any design is committed.

So: event-log-as-truth is real in the code. Snapshot-and-restore is real at the
engine level. **The server does not use either** — it treats Postgres as the
system of record and EHDB as a mirror, which is the inversion this pivot undoes.

---

## 3. The deciding question: embedded vs sidecar

The concern is contention — a request spike must not starve fsync, folds and
snapshots, and vice versa. Two facts from the code decide more of this than
first-principles reasoning does.

### Fact 1: the engine already isolates its own heavy work

```rust
// ehdb-l0/src/engine.rs:446
std::thread::Builder::new().name("ehdb-l0-uploader")
```

with an `mpsc` queue in front, and the comment on the receiving side:

> *"The append path never does this — durability is asynchronous (RFC §2.3)."*

Replication, the manifest write and the upload run on a dedicated named OS
thread. **Embedding EHDB does not put that work on the request path**, because
the library already took it off the caller's thread.

### Fact 2: the engine is synchronous, so its placement cannot be accidental

236 sync functions, 0 async. In an async server you *cannot* `.await` this. Any
call site must explicitly choose `spawn_blocking`, a dedicated runtime, or a
thread. **The type system forces the isolation decision to be made**, rather
than leaving it to discipline — which matters in a codebase whose recurring
failure is a guard that exists but is never reached.

Against that: the server today is a bare `#[tokio::main]` with no
`worker_threads` or `max_blocking_threads` tuning. There is no isolation
discipline in place — it would have to be built.

### The two options, concretely

**Embedded (in-process).**
- Contention handling: a **separate `tokio::runtime::Runtime` for storage** with
  its own thread count, plus bounded channels so a request spike blocks at the
  queue rather than consuming storage threads. Backpressure becomes a 429 at the
  API instead of a stall in the fold.
- What it does *not* solve: CPU shares and **heap**. One process means an L0
  memtable spike and a request spike share an allocator and an OOM. There is no
  cgroup boundary between them, and a panic on a storage thread can take the
  process down.

**Sidecar (same pod, UDS, own limits).**
- Contention handling: **by construction.** Per-container CPU/memory limits mean
  the kernel enforces the split; no discipline can erode it. This is a real and
  honest advantage and it is exactly what was asked about.
- Locality is preserved — same pod, same node, no ClusterIP, no DNS, no
  cross-node hop. It is *not* the current relay.
- What it costs: **a new IPC boundary on the hot path.** Smaller than the relay,
  but the same shape — and the shape is what produced
  [#320](https://github.com/noetl/ai-meta/issues/320) (no retry, plus a 90 s
  pool handing a dead socket to every retry) and the two parity oracles of
  [#325](https://github.com/noetl/ai-meta/issues/325)/[#326](https://github.com/noetl/ai-meta/issues/326).
  Every boundary needs a retry policy, an idempotency key, a liveness story and
  a parity check, and we have paid for all four of those on the current one.
- Plus: a second process to supervise, start-order dependency, and a
  serialization cost per append.

### Recommendation: **embedded, behind a trait, with a dedicated storage runtime**

Grounded in the code rather than in preference:

1. **The heavy work is already off the request path** (Fact 1). The sidecar's
   headline benefit is largely already provided by the library's own thread; the
   part that remains is CPU/heap sharing, which is a *sizing* problem.
2. **The sync API forces explicit placement** (Fact 2), so the isolation is
   structural rather than remembered.
3. **The pivot's whole purpose is to delete a boundary.** Replacing a remote
   boundary with a local one keeps the entire class of failure — delivery,
   ordering, idempotency, parity — that this reorientation exists to eliminate.
   A UDS is better than a ClusterIP, but "better boundary" is a different goal
   from "no boundary".
4. **Per-shard ownership bounds the working set** (§4), so the heap-sharing risk
   scales down as shards are added — the same lever that handles capacity.

**Make it reversible.** Introduce the local router *as a second implementation
of the same trait the network client already satisfies*. That seam is the
existing `PublishRouter` shape, and keeping it means a sidecar transport can be
added later without re-architecting — the decision is a config choice, not a
rewrite. Given the contention concern is legitimate and I cannot measure it
before the work exists, preserving the escape hatch is worth more than being
right now.

**What would change my recommendation:** a measurement showing the fold or
compaction consuming enough CPU to affect API p99 under realistic load. That
measurement does not exist today and should be taken on the embedded prototype
before committing — if it goes the other way, the trait boundary is how you
switch.

---

## 4. Sharding and the single-writer guarantee

**The sharding function already exists in the server:**

```rust
// server/src/sharding.rs:192
pub fn shard_for(execution_id: i64, shard_count: u32) -> u32   // xxhash64
```

with `ShardConfig::owns` in `affinity.rs` and `NOETL_SHARD_INDEX` /
`NOETL_SHARD_INDEX_FROM_HOSTNAME` for StatefulSet-ordinal assignment.

**Prod today: `replicas: 1`, `NOETL_SHARD_COUNT` unset (⇒ 1).** The server is a
single unsharded Deployment.

### Does per-shard ownership dissolve the election?

Mostly, and it is worth being precise about why. EHDB has
`ShardElection<S: LeaseStore, C: Clock>` with `try_acquire`/`renew` — note it is
already **per-shard**, not global. With `shard_count = 1` a per-shard election is
*de facto* a global one; that is a consequence of the current topology, not of
the design.

If each server shard sole-owns its partition's engine in-process, then **there is
no second candidate to arbitrate between**, provided the orchestrator guarantees
one live pod per ordinal — which is precisely what a StatefulSet provides. The
election does not need to be replaced; it becomes degenerate, and its lease
machinery can be retained as a safety belt against split-brain during rollout
rather than as the primary mechanism.

⚠ The honest caveat: a StatefulSet guarantees at-most-one *pod* per ordinal, not
at-most-one *writer* — a partitioned-but-alive old pod is the classic exception.
Retaining the lease (or a fencing token, which `ehdb-reference/src/fencing.rs`
already has) is what makes the guarantee hold during rollovers. "By
construction" is true for the steady state and needs the fence for the
transition.

**Scaling = more shards**, which is the same lever as
[#318](https://github.com/noetl/ai-meta/issues/318) (the system pool is a fixed
2-shard capacity with no autoscaler) rather than a new one.

---

## 5. What the pivot eliminates, and what it costs

### Dissolved — not fixed, but made impossible

| today's problem | why it stops existing |
| :-- | :-- |
| [#320](https://github.com/noetl/ai-meta/issues/320) mirror loss | there is no mirror. The event log *is* the store; nothing is copied to a second place, so nothing can be dropped between them |
| [#325](https://github.com/noetl/ai-meta/issues/325)/[#326](https://github.com/noetl/ai-meta/issues/326) cross-store parity | two stores are what parity compares. One store has nothing to disagree with — and the comparator, its flag, its alert and its two oracles all go away |
| C5 / global election | §4: sole ownership per shard leaves nothing to elect (with a fence for rollover) |
| [ehdb#332](https://github.com/noetl/ehdb/issues/332) remote tier shares the writer's PVC | the tier is not remote. `FailureDomain::LocalDevice` becomes the honest declaration rather than a defect, because replication moves to a genuinely separate substrate or is not claimed |
| the phantom-tier-volume incident (2026-09-08) | a manifest declaring storage for a separate tier service has no referent once there is no separate tier service |
| the relay's retry / pool / liveness tuning | no relay |

That list is the argument for the pivot. Six problems in five subsystems all
trace to the same root: **the store is somewhere else.**

### Honest costs

1. **Rework the writer.** `noetl-worker`'s writer mode, its nine HTTP faces
   (:9100–:9110) and every client of them. The engines survive; the service
   wrapper does not.
2. **Build the local router.** Small (§1), but it must handle ordering,
   backpressure and the sync/async boundary correctly — the append path is the
   hot path.
3. **Build the recovery driver.** §2: restore-then-replay-tail is not wired, and
   a durable per-shard cursor appears to be missing. This is the piece most
   likely to be underestimated, because the primitives existing makes it *look*
   done.
4. **Invert the system of record.** Today Postgres is authoritative and EHDB
   mirrors it. Every read path that goes to `noetl.event` — the parity
   comparator, the sweep, `project_events`, the status projection — assumes
   that. This is the largest piece of work and it is not in EHDB at all.
5. **Migrate a running system.** Prod has 2,390 executions and a live event log.
   The cutover needs a dual-read period, which reintroduces two stores
   *temporarily* — with the parity machinery we would otherwise be deleting.
   That irony should be planned for, not discovered.
6. **Per-shard storage sizing.** Each server pod gains a PVC and a memory
   budget for its engine. Autopilot scheduling, PVC-per-ordinal and node
   pressure all become server concerns.

### What I could not verify

- Whether a durable per-shard apply-cursor exists (§2). I searched and did not
  find one; absence of evidence here is weak.
- The actual CPU cost of folds/compaction under load — no measurement exists, and
  it is the input the embedded-vs-sidecar call would most benefit from (§3).
- Whether any EHDB HTTP face has a consumer outside NoETL. If one does, the
  service wrapper cannot simply be deleted.

---

## Recommended sequencing

Nothing below is authorized; this is the shape the work would take.

1. **Prototype the local router** behind the trait, in kind, single shard, with
   the storage runtime split. Measure API p99 against a fold-heavy load. This is
   the experiment that settles §3 with data instead of argument.
2. **Wire restore + replay-tail** and prove recovery from a killed pod without
   Postgres in the path — the claim in §2 that is currently untested.
3. **Invert one read path** (status projection is the smallest) and run it
   dual-read against Postgres, using the existing parity comparator as the
   migration oracle. It is the right tool for this exactly once, on the way out.
4. Only then: shard, retire the writer service, delete the mirror.

Steps 1 and 2 are cheap and answer the two open questions. Neither requires
touching prod.
