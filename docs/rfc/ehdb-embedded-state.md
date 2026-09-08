# EHDB as embedded state — routing and distribution

**Status: design. Decision locked on the embedding question. Nothing is built,
and nothing touches prod.**

**Decision (owner, 2026-09-08): EHDB is embedded into the sharded NoETL API
server. One unit per shard. Not a sidecar.**

The reasoning that settles it: the API server's job *is* to route and marshal
internal data, issue commands and write events. API and storage are **one logical
workload**. If the API stack stalls, storage stalling with it is *correct* — they
share fate by design, so there is nothing to isolate. The sidecar option is
dropped, and the contention question it existed to answer is dissolved rather
than traded off.

**Async keeps its place as a throughput tool *within* a shard** — folds,
snapshots and compaction off the append path — **not as an isolation boundary
between API and storage.** The code already works this way: `ehdb-l0` runs
replication, manifest writes and uploads on a named OS thread
(`engine.rs:446`, `"ehdb-l0-uploader"`) behind an `mpsc`, with *"The append path
never does this — durability is asynchronous"* in the source. Nothing needs
decoupling that is not already decoupled.

**With embedding settled, the design problem is routing and distribution.** This
is the RocksDB-in-Flink pattern taken to its distributed form: Flink partitions
state by key and shuffles records to the owning partition. NoETL needs the
equivalent, extended across regions. The rest of this document is that problem.

Grounded in `ehdb@49fdefc`, `server@6f23a58`, prod as observed 2026-09-08.

---

## 0. What embedding is, in one paragraph, and why it is close

All 11 EHDB crates are libraries; the workspace has **one** binary. What runs as
`noetl-cmdbus-writer` is the `noetl-worker` binary in writer mode — our own
process wrapping a library. Every engine has `open(config, substrate)` and
`cold_load(config, substrate)`. The server links `ehdb-l0` and **never opens an
engine**: `D1EventLog` is only a type parameter to `PublishRouter`, which holds
`PhantomData` and can only `connect(shard_count, addrs)` over TCP. **The engine
is one constructor away.** The work is not in EHDB; it is in everything built on
the assumption that the store is elsewhere — and, as §1–§4 show, in routing.

**Topology and membership** — how an instance learns where a shard's owner
is, and why that table is a hint and never an authority — is in
[`ehdb-topology-membership.md`](ehdb-topology-membership.md).

**Packaging and integration** — the library boundary, per-consumer crate
surface, the in-process/transport line, and the KEDA + gateway face migration —
are in the addendum [`ehdb-packaging.md`](ehdb-packaging.md).

---

## 1. Shard ownership and request routing

### What exists, and it is more than expected

```rust
// server/src/sharding.rs:192
pub fn shard_for(execution_id: i64, shard_count: u32) -> u32   // XxHash64, LE bytes
```

`ExecutionAffinity` (`src/affinity.rs`) is a **working single-hop router**:

| piece | state |
| :-- | :-- |
| `owns(execution_id)` | **live** — 3 call sites: nonconvergence sweep, orphan sweep, `events.rs:2797` |
| `route_event()` → `Forwarded` / `ProcessLocally` | **live** at `events.rs:480` on `POST /api/events` |
| loop guard (`AFFINITY_FORWARDED_HEADER`) | present — *"one hop, never a loop"* |
| `owner_base_url()` via `NOETL_PEER_URL_TEMPLATE` `{shard}` | present |
| shard index from StatefulSet ordinal hostname | present |
| per-outcome metrics | present |

This is not a sketch. It is a keyed-shuffle for one endpoint, with the hard parts
(loop protection, shard-map skew tolerance) already handled.

**⚠ Correction to a note I have carried:** I have recorded
`NOETL_STATE_AFFINITY_ROUTE` as "fully inert, one reader zero callers" (#266).
That is true of *that env flag*. It is **not** true of the affinity layer —
`owns()` and `route_event()` are both reached. The inert flag and the live router
are different things, and conflating them understates what exists.

### ⚠⚠ The one behaviour that must change: degrade-to-local

`route_event` degrades to `ProcessLocally` on **every** failure — owner
unreachable, non-2xx, undecodable body:

```rust
"execution-affinity: owner unreachable; degrading to local processing"
```

Under today's topology that is right: Postgres is the system of record, every
replica can write it, so a failed forward costs ordering, not data.

**Under embedded per-shard ownership it is a correctness violation.** Writing
locally means writing into *this* shard's event log for an execution *another*
shard owns — a permanent fork of the log, silently, on a transient network
error. The single-writer guarantee is exactly what embedding buys, and
degrade-to-local spends it.

> **Embedding requires this to become fail-closed: a failed forward is a 503,
> not a local write.** This is the single most important behavioural change in
> the pivot, and it is a three-line change guarded by a much larger question —
> what the caller does with a 503 — which belongs in the retry/backpressure
> design, not here.

### The shard key, and where it stops working

`execution_id` is the right key for the event log: an execution's events are all
under one id, so per-execution locality is total and every hot path
(`append`, `fold`, `get_state`) is shard-local.

It is the wrong key for everything else, and the code already knows this:

| table | read sites | mention `execution_id` |
| :-- | --: | --: |
| `noetl.event` | 86 | 17 |
| `noetl.command` | 11 | 7 |
| `noetl.catalog` | **31** | **0** |
| `noetl.credential` | 10 | 0 |
| `noetl.keychain` | 7 | 0 |
| `noetl.runtime` | 9 | 0 |

Catalog, credentials, keychain and the runtime registry are **not
execution-scoped**. `ExecutionService::list` already names the resolution:

> *"per-shard fan-out + **cluster-master catalog** lookup … results are merged,
> catalog paths are looked up once on the cluster master, stitched in"*

**So NoETL already has Flink's two-tier state split**: *keyed state* (sharded by
`execution_id`) and *broadcast state* (catalog, credentials, runtime — global,
read-mostly, one authority). The embedded design does not invent this; it
inherits it, and the design work is to make the broadcast tier explicit rather
than incidental (today it is "whichever pool is the master").

---

## 2. Cross-shard requests

### The precedent exists but is the wrong shape

```rust
// server/src/db/pool.rs:284
pub async fn for_each_shard<F, Fut, T, E>(&self, mut f: F) -> Result<Vec<(u32, T)>, E>
```

with `find_first` beside it, over-fetch handling (`limit + offset` per shard,
merged then paginated), and a documented sequential-await choice:

> *"Sequential await — simple and dep-free. Parallelism across shards is a
> Phase G concern … For N=2-4 shards … sub-10ms per query."*

**But it fans out over `DbPool`s, not peers.** Today one server process holds N
connection pools and can reach *every* shard's data itself. That is
"one process, N storage partitions" — and it is precisely what embedding ends.

> **`for_each_shard` is a local loop today and becomes a distributed
> scatter-gather under embedding.** Its latency assumption ("sub-10ms per query")
> becomes a network RTT to a peer pod, its failure model changes from "a pool
> errored" to "a peer is down or partitioned", and its sequential await becomes a
> real serial cost that has to be parallelised.

### The size of the surface

**70 cross-execution `noetl.event` queries** in the server. Not all become
scatter-gathers — many are admin/diagnostic and can be per-shard — but each one
must be classified, and that classification is the bulk of the routing work:

| class | routing | examples |
| :-- | :-- | :-- |
| **keyed** — carries an `execution_id` | forward to owner (§1 machinery, already built) | `/api/executions/{id}`, `/api/events`, status, cancel |
| **fan-out** — spans executions, bounded | scatter to all shards, merge, paginate (`for_each_shard`, made distributed) | `/api/executions`, dashboard stats |
| **broadcast** — non-keyed data | cluster-master or replicated read-only cache | catalog, credentials, runtime |
| **sweep** — spans executions, unbounded | run *per shard, locally* — never gather | nonconvergence sweep, orphan sweep (already use `owns()`) |

The fourth row matters: the sweeps already filter by `owns()`, so they are
**already** written for a per-shard world. That is the shape every unbounded
scan should take — the gather is avoided rather than optimised.

### What has no answer yet

A fan-out that needs a **consistent** view across shards. `/api/executions`
merges independent per-shard reads taken at different instants; that is fine for
a listing and wrong for anything that must not observe a torn state. Nothing in
the code distinguishes the two today because a single Postgres made the question
moot.

---

## 3. Multi-region and multi-cluster — the hard part

### What exists: nothing for data placement

The only region concept in the server is **credential residency** —
`residency: strict` region-locks a keychain entry, with a cross-region broker
and a `Residency violation: … region-locked to X; this server is in Z` error.
That is a policy boundary for secrets, not a placement or routing mechanism.
There is no region in the shard key, no region-aware routing, no cross-cluster
transport. This is greenfield.

### Routing to the right cluster is the easy half

Extend the key. `shard_for(execution_id, N)` becomes a two-level resolution —
region, then shard within region — and the natural encoding is in the id itself:
`execution_id` is a **snowflake**, so a region field can be carried in the id the
way `machine_id` already is (`agents/rules/observability.md` Principle 3 puts
generation application-side precisely so the id is known before any round trip).
An execution then names its own home region, and routing is a lookup, not a
directory.

The cost is that **an execution's home region is fixed at mint time**. Moving one
is a migration (§4), not a route change. For a workload where an execution is
minutes-to-hours long, that is the right trade.

### Rebuilding across shards *and* regions is the genuinely hard part

Replay is a fold. The question is what the fold is a fold *over*, and there are
three cases that look alike and are not:

**(a) Per-execution replay — solved by the partitioning.**
Every event for an execution is in one shard's log, ordered by that log's
sequence. Rebuilding one execution's state is a shard-local fold with a total
order. No coordination. This is the common case and the pivot makes it *easier*
than today, because today it requires reading Postgres and the tier and
reconciling them (#325/#326).

**(b) Whole-system rebuild — embarrassingly parallel, if you accept per-shard
timelines.** Every shard folds its own log independently; there is no
cross-shard interaction because state is keyed and keys do not span shards.
Runtime is the slowest shard. Also fine.

**(c) A rebuild that needs a consistent cut across shards — no answer today, and
this is the one to design.**

Consider: "reconstruct the state of the whole platform as of time T", or "replay
region A's log into region B and get a coherent result." Per-shard logs have
**independent sequence numbers**. There is no global total order. Snowflake ids
give an approximate one — they are time-ordered by construction — but
approximate is exactly the wrong word here: clock skew between nodes means
`id_a < id_b` does not imply `a` happened before `b`, and across regions the
skew is larger and the partition risk real.

Three honest options, with what each costs:

| approach | gives | costs |
| :-- | :-- | :-- |
| **Declare per-execution consistency only** | nothing to coordinate; (a) and (b) are the whole story | "state of the system at T" becomes undefined. Any feature needing it — a global audit as-of, cross-execution invariants — is off the table |
| **Global sequencer** | a true total order | a single serialisation point; kills the scaling property the sharding exists for. Reintroduces exactly the centralisation this pivot removes |
| **Watermarks + barriers (Flink's own answer)** | a consistent distributed snapshot without a global lock | Chandy-Lamport: a barrier injected into every partition's stream, each shard snapshots on barrier receipt, the snapshot set is a coherent cut. Needs a coordinator, barrier alignment, and a story for a shard that does not respond |

**Recommendation: declare per-execution consistency as the contract, and treat
the consistent-cut case as a separate, later, opt-in mechanism modelled on
barriers.** Reasons: (a) and (b) cover every use we actually have — replay,
recovery, projection rebuild are all per-execution or per-shard; option 2
forfeits the point of the design; and option 3 is a large, well-understood piece
of machinery that should be built when a requirement names it, not speculatively.

**⚠ The cost of that choice must be written down where it will be read**, because
it is the kind of constraint that gets discovered rather than remembered: with
per-execution consistency, *there is no defined global as-of*, and any future
feature that assumes one is a design change, not an implementation.

### Cross-region replication is a separate decision

Two shapes, and they should not be blurred:

- **Regions partition the key space** (an execution lives in exactly one region).
  No cross-region consistency needed; cross-region traffic is routing only. This
  composes with the recommendation above.
- **Regions replicate each other** (an execution's log exists in two regions).
  Now you need conflict resolution or consensus, and the single-writer guarantee
  that per-shard ownership buys is spent again at the region boundary.

⚠ Note `ehdb-l0` already has `ReplicaTarget`, `open_replicated`, and a
`FailureDomain` enum that **refuses a replica set built from undeclared
domains** — `LocalDevice { device_id }` treats two paths on one disk as one
domain. The primitives lean toward the replication shape. That is a reason to
decide deliberately rather than let the available API choose.

---

## 4. Rebalancing

### Nothing exists

`ShardConfig::new(shard_index, shard_count)` is read from env at boot
(`NOETL_SHARD_INDEX` / count, or the StatefulSet ordinal). There is no
rebalancing, no ownership handoff, no migration path. Prod runs `replicas: 1`
with `shard_count` unset (⇒ 1).

### ⚠ The hash choice makes resizing maximally expensive

`shard_for` is `XxHash64(execution_id) % shard_count`. Changing `shard_count`
from N to N+1 remaps **roughly every key** — with embedded state, that means
moving nearly all of it. Modulo hashing is fine when the shard map only selects
a connection pool (today) and near-worst-case when it decides where terabytes of
state live.

**This is the change with the longest lead time**, because the hash is baked into
`command_bus.rs` too (*"`shard_for_execution` is byte-identical to the
server/worker `shard_for`"*) — any replacement must move both together or the
command bus and the server will disagree about ownership, which is the one
disagreement that cannot be tolerated.

Options: **consistent hashing / rendezvous** (moves ~1/N of keys on a resize) or
an **explicit partition table** (fixed large P partitions mapped to shards; a
resize moves partitions, not keys — this is Kafka's and Flink's model, and it
makes handoff a unit of work rather than a scan).

**Recommendation: an explicit partition table with P fixed and P ≫ N.**
It makes rebalancing a bounded, resumable, observable operation, and — decisively
— an execution's partition never changes, so a partition can be handed off
without any execution changing identity mid-flight.

### What a handoff has to do

Given per-partition state = event log + projection snapshots:

1. Source shard **stops accepting** writes for the partition — fail-closed (§1),
   forwarding to the new owner once it is ready.
2. Ship the **latest projection snapshot** (`cold_load` is the restore half, and
   it exists) plus the **log tail** after that snapshot.
3. Target **replays the tail** onto the snapshot — the missing driver from §5.
4. Ownership flips in the shard map; in-flight requests get one retry.
5. Source drops the partition after a retention window.

Steps 2–3 are exactly "restore snapshot + replay tail", which is also the
recovery path. **Building it once serves both**, and that is the strongest reason
to build it early.

⚠ Step 4 is where a fence is required, not optional. A StatefulSet guarantees
at-most-one *pod* per ordinal, not at-most-one *writer* — a partitioned-but-alive
old owner is the classic split-brain. `ehdb-reference/src/fencing.rs` has the
token machinery; ownership flips must carry it.

---

## 5. What the pivot dissolves, and what it costs

### Dissolved — made impossible, not fixed

| today | why it stops existing |
| :-- | :-- |
| [#320](https://github.com/noetl/ai-meta/issues/320) mirror loss | there is no mirror; nothing is copied, so nothing can be dropped between copies |
| [#325](https://github.com/noetl/ai-meta/issues/325)/[#326](https://github.com/noetl/ai-meta/issues/326) cross-store parity | one store has nothing to disagree with — comparator, flag, alert and both oracles go |
| C5 / election | per-shard sole ownership leaves nothing to elect (fence retained for handoff, §4) |
| [ehdb#332](https://github.com/noetl/ehdb/issues/332) remote tier on the writer's PVC | the tier is not remote; `FailureDomain::LocalDevice` becomes an honest declaration |
| the 2026-09-08 phantom-volume incident | no separate tier service ⇒ no storage to declare for one |
| the relay's retry / pool / liveness tuning | no relay |

Six problems, five subsystems, one root: **the store is somewhere else.**

### Costs, honestly

1. **Fail-closed forwarding** (§1) — small change, large consequence; needs the
   caller-side retry story.
2. **Classify 70 cross-execution queries** (§2) into keyed / fan-out / broadcast
   / per-shard-sweep. Mechanical, large, and the real bulk of the work.
3. **Make `for_each_shard` distributed** — parallel, partial-failure-aware. Its
   own sequential-await comment already anticipates this as "a Phase G concern".
4. **Build restore + replay-tail.** `cold_load` exists; the driver and a durable
   per-shard apply-cursor do not appear to. Most likely to be underestimated,
   because the primitives existing makes it look done. Serves recovery *and*
   rebalancing (§4).
5. **Replace modulo hashing with a partition table** (§4), in the server and the
   command bus **together**.
6. **Invert the system of record** — every read path assumes Postgres is
   authoritative. Largest piece, and not in EHDB at all.
7. **Make the broadcast tier explicit** (§1) — today "cluster master" is
   whichever pool.
8. **Migrate a live system**: 2,390 executions, needing a dual-read period that
   *temporarily reintroduces two stores* — using the parity comparator we would
   otherwise delete. Plan for that irony; do not discover it.

### Migration path from today

1. **Embed behind the existing seam.** Add a local router as a second impl
   alongside `PublishRouter::connect`; single shard; server opens its own engine.
   Kind only. Nothing in prod changes because `shard_count = 1` makes ownership
   trivially true.
2. **Wire restore + replay-tail**; prove recovery from a killed pod with Postgres
   out of the path. Answers §5.4 and unlocks §4.
3. **Flip one read path** to the embedded projection, dual-read against Postgres,
   using the parity comparator as the migration oracle — the right tool for this
   exactly once, on the way out.
4. **Fail-closed forwarding + partition table**, still at N=1 (both are no-ops at
   one shard, which is the safest place to land them).
5. **N > 1 in kind**: exercise forwarding, distributed fan-out, and a partition
   handoff.
6. Only then: prod cutover, retire the writer service, delete the mirror.
7. Multi-region after single-region sharding is boring.

Steps 1–2 need no prod access and answer the two questions that most affect the
rest.

### Still unverified

- A durable per-shard apply-cursor — searched, not found; weak evidence.
- Whether any EHDB HTTP face has a consumer outside NoETL. If one does, the
  service wrapper cannot simply be deleted.
- Fold/compaction CPU under load. **No longer decision-relevant** — the owner's
  fate-sharing argument settles the placement question — but still needed for
  shard sizing.
