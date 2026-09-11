---
spec: 2026-09-11-ehdb-resilient-core
status: draft
created: 2026-09-11T17:30:00Z
owner: Claude (ai-meta session 2026-09-11)
---

# EHDB as a resilient KV core for event sourcing, projections and context — no SQL layer

## Problem

EHDB is the storage substrate for noetl's platform state. It has a strong
storage layer and ten implemented datasets, and it is live in production as the
command bus and event bus. What it does **not** have is the property that makes
a database a database rather than a very good file format:

> **Lose a node, keep serving correct reads and accepting writes, without losing
> an acknowledged write.**

CockroachDB gets that property from one place — layer 4, Raft-replicated ranges
with quorum writes and leaseholder reads. EHDB today acknowledges a write when it
is `fsync`'d to **one** local disk, and in production that disk's "replica" is a
subdirectory of the same PVC.

The owner's thesis is that the resilient KV core (Cockroach layers 5→2) is the
valuable part and the SQL layer is legacy-compatibility cost noetl does not need.
This spec agrees, and scopes the work to: **make the KV core survivable, and put
event sourcing + projections + context directly on it.**

## Goals

- A layer-by-layer map of CockroachDB's architecture onto EHDB's actual code,
  honest about existence vs implementation vs reachability.
- A decision on how EHDB achieves survivability, with a recommended
  consensus/replication approach and the reasoning that rejects the alternatives.
- A target architecture: the minimal resilient KV core, with D1 (event log),
  D3 (projections) and context handling sitting directly on it.
- A staged plan from today to "done", with shipped work slotted in and every
  stage reversible.

## Non-Goals

- **A SQL query engine, a SQL dialect, or Postgres wire compatibility.**
  Explicitly out of scope, permanently. noetl's access patterns are
  append-event, fold-projection, get/scan-by-key and range-by-sequence. None of
  them need a planner, an optimiser or a parser.
- A general MVCC KV store. EHDB's ordering authority is the event sequence, not
  a timestamp oracle. (See Open Question Q3.)
- Distributed multi-key ACID transactions across shards (Cockroach layer 2 in
  full). What noetl needs is narrower — see "Transactional" below.
- Changing anything in production. This spec is design only.
- Re-litigating Postgres's role. Postgres remains authoritative for
  `noetl.event` until a separate, owner-gated cutover says otherwise.

## Constraints

- **Self-sufficient means no external database or coordination service to
  deploy, operate, quorum or upgrade** — not "no dependencies". A library that
  compiles into the binary is fine and preferred over hand-rolling
  (`agents/rules/self-sufficiency.md`).
- ⚠ **Do not hand-roll consensus.** Failure detectors, elections and quorum
  protocols fail *silently* when written badly — the failure mode this codebase
  is already most prone to.
- Postgres stays authoritative and untouched for the duration of this work.
- Everything reversible; every stage independently revertable.
- Platform-only. Business data never enters EHDB.

## Layer map — CockroachDB → EHDB, as implemented

Grounded in `noetl/ehdb` at `24e63b8` (tag `v0.2.0`), the tag noetl-server pins.

⚠ **Scope note that changes how the rest of this table reads:** noetl-server
depends on **`ehdb-l0` and `ehdb-feed` only**. `ehdb-reference` (23,949 LOC),
`ehdb-service` and `ehdb-transaction` are **not in the production dependency
path**. Several capabilities below exist in the tree but are not linked into the
running binary — a distinction that "does EHDB have X" cannot express.

### L5 — Storage (Cockroach: MVCC KV on Pebble)

| | |
| :-- | :-- |
| **Has** | Immutable parts with a ClickHouse-style meta-catalog: `Manifest` (one `PartMeta` per part), per-part `SparseIndex` (granule → offset), min/max sort-key pruning, per-part and per-granule blooms over `execution_id`, small→big merge/compaction with atomic manifest swap, retention as drop-partition + orphan GC, a columnar per-field codec, and `fsync`-per-append (`FlushPolicy::EveryAppend`) for D1. |
| **Partial** | The columnar codec is provided but not yet the event-tier encoding. |
| **Missing** | Nothing that matters. |

**Verdict: this layer is done, and it is EHDB's strongest.** It is not an MVCC KV
store and should not become one — it is an append-only log-structured store whose
version axis is `global_sequence`. For event sourcing that is a better fit than
MVCC, and mutable state is already modeled correctly as a fold over an
append-only op log (D2 `command_queue` does exactly this).

### L4 — Replication (Cockroach: Raft, quorum writes, leaseholder reads)

**This is the gap.** In detail, because the pieces fail differently:

| Piece | State |
| :-- | :-- |
| N-way copy of **sealed** parts | **Implemented** (L0.6) — `ReplicaTarget`, replica set, `PartMeta::replicas`, write-once per replica, read fallback. |
| Quorum on the **write path** | **Missing.** An append is acked after `fsync` to one local part. There is no second acceptor. |
| The **unsealed tail** | **Unreplicated by construction.** A part replicates only once sealed. |
| Bounding that window | `seal_max_age` exists, defaults to `None`, **and** `seal_aged_parts` has **no production caller** — only tests and one example. Two independent reasons it cannot fire. |
| Independent failure domain | **Absent in prod.** `failure_domain.rs` says it plainly: `/data/eventbus` and `/data/eventbus/ehdb-tier` are one PVC, so "an RF of N over one domain is an RF of 1 wearing a larger number." |
| Single-writer enforcement | Rests on `StatefulSet replicas: 1` — "an orchestration preference, not a mutual-exclusion primitive." |
| Election | Implemented as a state machine, **not authoritative** ("nothing here decides who writes"), K8s adapter **not implemented**, and in `ehdb-reference` — **not linked into the server**. |
| Fencing (Invariant F) | Implemented, **shadow mode — refuses nothing**, same crate, same non-linkage. |
| Leaseholder reads | **Absent.** No concept. |

So the honest statement is: **EHDB has replication for the data that is already
safe, and none for the data that is at risk.** Sealed parts are immutable and
byte-identical, so copying them is easy and solved. The bytes that can actually be
lost — acked, unsealed, on one disk, for an unbounded time — have RF=1.

⚠ The codebase is not hiding this. `unreplicated.rs` exists specifically to
*measure* the window, and explains why the pre-existing metric could not: it was
accumulated from **seal**, so records waiting in an unsealed part contributed
nothing, and "a dashboard built on it reads healthy in precisely the scenario
where events sit unreplicated." That is good engineering. It is also not
durability.

### L3 — Distribution (Cockroach: ranges, auto-split, rebalance)

| | |
| :-- | :-- |
| **Has** | Static hash partitioning — `shard_for(execution_id) = hash % shard_count`; an affinity layer; foca gossip membership (Scuttlebutt + phi-accrual) landed and D8 `RuntimeDataset` as the topology projection. |
| **Partial** | Resharding = changing `shard_count`, which moves a bounded fraction of partitions. Offline, not an online split. |
| **Missing** | Key ranges, automatic split/merge on size or load, rebalancing, and a range→owner directory. |

**Verdict: partial, and mostly fine.** Cockroach needs ranges because a SQL
keyspace is unbounded and arbitrarily skewed. noetl's keyspace is
`execution_id`, which is a snowflake — uniformly distributed by construction. A
hash partition over it does not develop hot ranges the way a SQL primary index
does. **Ranges are largely SQL-layer tax**; what EHDB actually lacks is not
splitting but *online* reshard without a stop.

### L2 — Transactional (Cockroach: atomic multi-key)

| | |
| :-- | :-- |
| **Has** | Append-time idempotency (`dedupe_capacity`, per-shard key memory), atomic manifest swap on merge, and single-append atomicity. `ehdb-transaction` provides a `CommitTransaction` / `TransactionSequence` / `Mutation` log — but it is a **control-plane metadata mutation log** (catalog/stream/retrieval/system/storage) used by `ehdb-reference` and `ehdb-service`, **not** a data-plane transaction engine, and **not linked into noetl-server**. |
| **Missing** | Atomic multi-key / cross-dataset writes on the L0 path. |

**Verdict: mostly not needed, and the one case that matters is narrow.** Event
sourcing wants *one* atomic primitive: **append these N events at this expected
sequence, or fail** — a compare-and-append, not a transaction manager. Everything
downstream is a deterministic fold, which needs no transaction at all. The
cross-dataset case (append D1 event + update D3 projection atomically) is better
solved by *not needing it*: the projection is derived, so it may lag, which is
precisely the serve-on-behind design already in flight.

### L1 — SQL

**Not present, and deliberately never will be.** This is the layer the owner's
thesis removes, and removing it also removes the reason for most of L2 and much
of L3.

## The resilience decision

### What survivability requires, minimally

1. An acknowledged write survives the loss of the accepting node.
2. After that loss, some other node can serve reads that include that write.
3. Exactly one writer per shard accepts appends at any time, enforced — not
   preferred.

EHDB satisfies none of these today. (3) is the sharpest, because the event-log
tier has been `primary` and serving on prod since 2026-08-13 while single-writer
rested on `replicas: 1`.

### Why "no consensus" was right, and where it stops being right

The existing design decision — documented in `ehdb-l0/src/lib.rs` §2.7 — is
**N-way copy of immutable parts, no consensus, the HDFS block-replication
model**, with the *fungible-writer* property: on writer death another node
cold-loads sealed parts from a surviving replica and resumes. That explicitly
"retires the per-shard-Raft T-RF plan."

**That argument is correct, and this spec keeps it.** Immutable, byte-identical
objects cannot conflict, so replicating them needs no agreement. Running Raft
over sealed parts would add cost and no guarantee.

**But the argument only covers sealed parts.** It says nothing about the
interval between an ack and a seal, because during that interval there is no
immutable object yet — there is a single node's opinion. The fungible-writer
property recovers *sealed* state; the tail is simply gone.

So the choice is not "Raft or not". It is **what the smallest thing is that needs
agreement**, and the answer is: the tail, and who owns it.

### Options

**Option A — finish the lease/fencing path (no consensus at all).**
Implement the K8s `LeaseStore` adapter, promote fencing from shadow to enforce,
set `seal_max_age` and drive `seal_aged_parts` on a timer, and point the second
replica at a genuinely independent failure domain (GCS).
- ✅ Cheapest; all four pieces are already designed, three partly built.
- ✅ Bounds and measures the window instead of leaving it unbounded.
- ❌ **Does not make an ack survivable.** A bounded window is still a window;
  writes inside it are still lost on node loss.
- ❌ Depends on the K8s API server — i.e. on etcd's Raft. Defensible ("etcd is
  already there") but it is an external coordination service, in tension with
  the self-sufficiency rule, and it makes EHDB unable to run outside Kubernetes.

**Option B — Raft over the unsealed tail only. ⭐ Recommended.**
A small per-shard Raft group replicating **only the active, unsealed tail**.
An append is acked when a quorum has it. On seal, the committed entries become an
immutable part, replicate by the existing N-way copy, and the Raft log truncates.
- ✅ Makes the ack survivable — the one property missing.
- ✅ **The Raft log stays tiny.** It holds one part's worth of records at most, so
  the expensive half of Raft — snapshot transfer, large state machines,
  compaction — mostly disappears: *the sealed part is the snapshot*, and the
  existing cold-load is the snapshot-restore.
- ✅ Solves single-writer properly. The Raft leader *is* the writer, and its term
  is a real, consensus-backed epoch — which is exactly the input Invariant F's
  fencing needs, replacing a clock-decided lease with a quorum-decided term.
  ⚠ This matters: `election.rs` itself notes "a Lease elects; it does not fence"
  and that a paused holder can believe a lease it no longer holds.
- ✅ Keeps every existing strength: storage layer, immutable parts, HDFS-style
  replication of sealed data, cold-load.
- ✅ Self-sufficient — a crate, no service to operate.
- ❌ Real work, and a new failure surface on the hot write path.
- ❌ Requires ≥3 EHDB nodes per shard group, which is a topology and cost change.

**Option C — full Raft-replicated ranges (Cockroach-style).** Rejected.
It re-solves sealed-part replication, which is already solved more cheaply by
immutability, and drags in the range/split/rebalance machinery that exists to
serve a SQL keyspace we are explicitly not building.

### Recommendation

**Option B, staged behind Option A.** A is not an alternative to B — it is the
first half of B and is valuable on its own: bounding and measuring the window,
and enforcing single-writer, are prerequisites whose absence would make B's
correctness unobservable. Do A first, get the measurement, then decide B with
the window's real size in hand.

**Library:** do not hand-roll. Two candidates:

| | `tikv/raft-rs` | `openraft` |
| :-- | :-- | :-- |
| Scope | Consensus module only — no storage, no transport | Full async framework incl. storage/network traits |
| Proven | TiKV in production at scale | Younger, smaller deployed base |
| Fit | You own the plumbing; more glue | Tokio-native, matches EHDB's async shape |

**Recommend `openraft`** — EHDB is already tokio-based and wants to own storage
behind a trait, which is openraft's seam. ⚠ But this is Q1, an explicitly open
question: the "battle-tested" argument for `raft-rs` is strong and this is
exactly the class where a silent-failure bug is most expensive. Decide it with a
partition/clock-skew harness, not from the README.

## Target architecture

```
   noetl storage requirements
   ┌──────────────┬──────────────┬─────────────────┐
   │ event log    │ projections  │ context         │   ← D1 / D3 / context
   │ (D1)         │ (D3)         │ handling        │
   └──────────────┴──────────────┴─────────────────┘
             │ append          │ fold            │ get/put
   ┌─────────────────────────────────────────────────┐
   │ resilient KV core                               │
   │  • compare-and-append at expected sequence      │  ← L2, narrowed
   │  • quorum-acked unsealed tail (Raft, per shard) │  ← L4, the gap
   │  • static hash partitioning + gossip membership │  ← L3, partial/adequate
   │  • immutable parts, N-way copy, cold-load       │  ← L4 sealed, done
   │  • manifest + sparse index + bloom + merge + GC │  ← L5, done
   └─────────────────────────────────────────────────┘
                    NO SQL LAYER
```

**Event sourcing (D1)** sits directly on compare-and-append. The event log *is*
the Raft-committed sequence; no translation layer.

**Projections (D3)** are deterministic folds over D1. They are derived, so they
may lag, and the serve-flip work in flight is exactly the discipline for serving
a lagging projection safely: serve a snapshot that is *behind* only when it is
verified against an authority at its own watermark, and make an *ahead* snapshot
structurally unrepresentable. ⚠ That work also produced the rule this layer must
keep: **a projection must never be verified against the store that produced it**
(noetl/server#424) — with a resilient core, the verifier is the quorum-committed
log rather than Postgres.

**Context handling** is get/put by key, scoped to `execution_id` — D4 KV over the
same engine, partitioned the same way, so a context read is shard-local to the
execution that owns it.

## Acceptance Criteria

- [ ] **AC1 — The layer map is grounded in code, not description.** Every "has /
      partial / missing" cites a file and, where it is a reachability claim, the
      call-site count that supports it.
- [ ] **AC2 — The durability window is measured on prod before it is engineered
      against.** `unreplicated.rs`'s tracker is exported and read; the report
      states the observed oldest-age distribution and the denominator.
- [ ] **AC3 — The window is bounded.** `seal_max_age` set, `seal_aged_parts`
      driven on a timer, and a **positive control** proving the timer fires on an
      idle shard (the flag alone is inert on exactly the shard it protects).
- [ ] **AC4 — The second replica is a genuinely independent failure domain**,
      enforced by `validate_replica_domains`, with a test that a same-PVC replica
      set is refused.
- [ ] **AC5 — Single-writer is enforced, not preferred.** Fencing promoted from
      shadow to enforce, with an observed refusal of a stale epoch — a real
      positive control, not a unit test alone.
- [ ] **AC6 — An acknowledged write survives the loss of its accepting node.**
      Demonstrated in kind: kill the leader mid-append, and every acked record is
      readable afterwards. This is the criterion that defines "resilient".
- [ ] **AC7 — Reads keep being served after that loss**, with a measured
      unavailability window.
- [ ] **AC8 — No SQL layer is introduced.** A guard that fails if a SQL parser,
      planner or wire-protocol dependency enters the tree.
- [ ] **AC9 — Every stage is independently revertible**, each with a rehearsed
      revert.

## Plan / Task Breakdown

**Stage 0 — shipped, slotted in.** Recovery folds from the durable tier (#307);
D1 mirror at the server chokepoint; embedded engine armed in shadow on prod
(v3.106.1, reachable); D3 serve-on-behind built and mutation-gated (v3.108.0);
**AC14 verification independence released as v3.108.1** (`b9bed030`), not yet
deployed. Foca gossip integrated; D8 `RuntimeDataset` is the topology projection.
All ten datasets D1–D10 now have real `Dataset` impls.

**Stage 1 — see the window (read-only).** Export the `UnreplicatedTracker`
snapshot as metrics; read it on prod. Answers "how big is the risk, actually",
and AC2 gates everything after it. No behaviour change.

**Stage 2 — bound the window.** `seal_max_age` + a timer driving
`seal_aged_parts`, with the positive control from AC3. Reversible by unsetting.

**Stage 3 — a real second failure domain.** Point `replica-1` at GCS; enforce
`validate_replica_domains`. This is the first point at which EHDB has genuine
redundancy for sealed data. Reversible by dropping back to one replica.

**Stage 4 — enforce single-writer.** Link the election + fencing work into the
server's dependency path (it is in `ehdb-reference` today, which the server does
not depend on — Q2), implement the `LeaseStore` K8s adapter, promote fencing
shadow → enforce. Reversible to shadow.

**Stage 5 — decide Raft (Q1), then quorum-ack the tail.** Only after Stages 1–4
have made the window visible, bounded and singly-owned. Per-shard group over the
unsealed tail; seal truncates the log. AC6/AC7 land here.

**Stage 6 — online reshard.** The remaining L3 gap. Deliberately last: it is the
least dangerous absence, since a snowflake keyspace does not develop hot ranges.

## Open Questions

- [ ] **Q1 — `openraft` or `tikv/raft-rs`?** Decide against a partition +
      clock-skew harness, not documentation. This is the highest-stakes
      dependency choice in the plan.
- [ ] **Q2 — Where do election and fencing live?** They are in `ehdb-reference`,
      which noetl-server does not depend on. Move them to `ehdb-l0`, promote them
      to a shared crate, or take a dependency on `ehdb-reference`? This blocks
      Stage 4 and is a smaller decision than it looks, but it must be made
      explicitly rather than discovered during implementation.
- [ ] **Q3 — Does anything need MVCC?** The spec asserts sequence-ordering is
      sufficient because every consumer is a fold. If any reader needs
      "as of time T" across datasets, that assertion is wrong and L5 changes.
- [ ] **Q4 — Minimum topology for Stage 5.** Raft needs ≥3 voters per shard
      group. What does that cost on Autopilot, and does it change the
      embedded-per-shard model? Possibly voters ≠ noetl servers.
- [ ] **Q5 — Is the K8s dependency acceptable long-term?** Stage 4 leans on the
      API server; Stage 5 would remove that need. If EHDB must run outside
      Kubernetes, Stage 4 is a bridge, not a destination.

⚠ This spec is **not approved** while Q1–Q5 are open.

## Verification Plan

| AC | How |
| :-- | :-- |
| AC1 | Review against the cited files; reachability claims re-derived by call-site count with a control needle. |
| AC2 | Prod metric read, with the denominator and the idioms covered. |
| AC3 | Kind: an idle shard with `seal_max_age` set seals only when the timer runs — the negative case (flag set, no driver) must also be shown. |
| AC4 | Unit: a replica set sharing a device id is refused; a distinct-domain set is accepted (both sides). |
| AC5 | Kind: two writers, one with a stale epoch; the store refuses. Counter observed moving 0 → ≥1. |
| AC6 | Kind: kill the leader mid-append; every acked record readable after. Denominator = acks issued. |
| AC7 | Same run, measured unavailability window. |
| AC8 | Dependency guard in CI. |
| AC9 | Each stage's revert rehearsed as `--dry-run=server` before its apply. |

## Linked Issues

- Coordination issue: noetl/ai-meta#339
- Umbrella: noetl/ai-meta#332 (EHDB embedded per shard)
- In flight: `specs/active/2026-09-11-d3-projection-serve-flip/` (D3), noetl/ai-meta#336
- Related defect: noetl/ai-meta#335
