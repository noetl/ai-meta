# RFC: Execution-partitioned event store — retire reconcile/re-drive

**Status:** RFC — design only. **No prod change, no code change, nothing merged.**
**Date:** 2026-09-24.
**Supersedes the mechanism of:** the reconcile / off-server re-drive / give-up-cap
line ([server#461](https://github.com/noetl/server/pull/461),
[#462](https://github.com/noetl/server/pull/462),
[#463](https://github.com/noetl/server/pull/463),
[ai-meta#315](https://github.com/noetl/ai-meta/issues/315)) — not by patching the
cap, but by removing the condition that makes re-driving necessary.
**Related open issues:** [#351](https://github.com/noetl/ai-meta/issues/351)
(tier saturation, ~36 s tail reads), [#344](https://github.com/noetl/ai-meta/issues/344),
[#345](https://github.com/noetl/ai-meta/issues/345).
**Composes with:** the multi-region EHDB plan and its 12 phase specs — ⚠ **not
yet on `main`**; they live on branch `docs/multiregion-ehdb-plan` at
`loops/active/2026-09-11-ehdb-resilient-core-phases/handover/MULTIREGION-EHDB-PLAN.md`
and `specs/active/2026-09-18-multiregion-ehdb/`. Read them with
`git show docs/multiregion-ehdb-plan:<path>` until that branch lands.

## How to read this

- **VERIFIED** — I ran the command or read the cited line.
- **VERIFIED (manifest)** — read from an ops manifest, not a live object.
- **ASSUMED** — plausible, untraced. Re-check before relying on it.

⚠ **All code citations are against `origin/main`, fetched 2026-09-24**, not the
local checkout. The local submodules were **ehdb 37, worker 16 and server 6
commits behind** when this work started, and the first pass of this diagnosis
was read off the stale tree. A stale checkout has produced a confidently wrong
answer in this program before; every load-bearing claim below was re-read with
`git show origin/main:<path>`.

---

## 1. Diagnosis — why the current design fails

### 1.1 The one-sentence version

> **The event store is ordered by a global sequence and partitioned by nothing.
> "Give me this execution's events" is therefore a filter over every event ever
> written, and "advance this execution" inherits that cost. The re-drive loop
> exists to paper over reads that time out; the give-up cap exists to bound the
> re-drive loop; and the cap counts polls on a loop that does not poll at the
> rate its units assume. Three mechanisms, all downstream of one storage
> decision.**

### 1.2 The storage model, as it actually is

**VERIFIED**, `ehdb/crates/ehdb-stream/src/lib.rs@origin/main`:

```rust
records: BTreeMap<StreamSequence, StreamRecord>,     // :231
```

The sole index is the **global stream sequence**. `execution_id` is not a key,
not a partition and not an index — it lives in the record's `subject`. So the
per-execution read is a scan:

```rust
fn replay_records(..., subject_filter: Option<&SubjectFilter>) -> Result<Vec<StreamRecord>> {   // :357
    let state = self.stream(tenant, namespace, stream)?;
    Ok(state.records.iter()
        .filter(|(sequence, _)| after.is_none_or(|cursor| **sequence > cursor))
        .filter(|(_, record)| subject_filter.is_none_or(|f| f.matches(&record.subject)))
        .map(|(_, record)| record.clone())
        .collect())
}
```

`read_execution` builds an exact subject filter and calls straight into it
(`ehdb-reference/src/eventlog.rs:574-591`). **VERIFIED.** So reading one
execution's chain is **O(total records in the stream)**, and the work is
proportional to everything every *other* execution ever wrote.

### 1.3 Three independent costs, and the code says so itself

The strongest evidence is a doc comment already in the tree
(`ehdb-reference/src/lib.rs:187-224@origin/main`). **VERIFIED**, quoted:

> *"`LocalReferenceRuntime::open` replays the entire JSONL log and rebuilds the
> in-memory `ReferenceDatabase` from scratch, so **every** driver call is
> O(log size). The EHDB event-log tier calls a driver method per mirrored event,
> which made the cost of mirroring one event proportional to everything mirrored
> before it."*

with a production measurement, tier store 161.7 MB:

| operation | latency |
| :-- | --: |
| `health` round trip (no store access) | 3.3 ms |
| `scan(limit=10)`, 8 KB returned | 835 ms |
| `read_execution`, 92 KB returned | 858 ms |

> *"The latency does not track the result size, because it is not the read: it
> is the replay in front of it. That fixed ~840 ms, paid 76 times, was ~82 s of
> a 91 s user-facing turn."*

So the three costs are:

| # | cost | status |
| :-- | :-- | :-- |
| **C-a** | **Cold replay** — every driver call reopens and re-parses the whole log, O(log size) | **Mitigated**, not fixed. `NOETL_EHDB_REFERENCE_RUNTIME_CACHE` caches one runtime per path — but it **defaults to FALSE** (`runtime_cache_enabled()` matches only `1\|true\|yes\|on` over `unwrap_or_default()`, `lib.rs:226`). **VERIFIED.** It is set `'true'` on the cmdbus-writer only — **VERIFIED (manifest)**, `ops/ci/manifests/noetl/cmdbus-writer-statefulset-prod.yaml:142`; not verified against the live object |
| **C-b** | **Per-read O(N) filter** — `replay_records` scans the whole `BTreeMap` on every call | **NOT addressed by the cache.** Caching removes the re-*open*; the linear filter is per call and remains |
| **C-c** | **One mutex per store** — every reader serialises | **By design and documented.** The same comment: *"each entry carries its own lock, so concurrent callers on one store **serialise exactly as they did** when each opened its own runtime"* |

⭐ **C-c is the amplifier.** C-b makes a read slow; C-c makes one slow read
block every other read of that tier. That is the shape of
[#351](https://github.com/noetl/ai-meta/issues/351) — *"~36 s tail reads stall
the writer, server and UI"* — and of the 2 s timeouts the comparator reported as
*"no comparable records"*, which were never about comparison at all: the reply
was empty because the read timed out.

### 1.4 Why the segment index does not close this

v6.1.4/v6.1.5 added a `.idx` of distinct execution ids per segment so a read
opens only segments that can hold the execution. **VERIFIED** that `idx` appears
in `ehdb-reference/src/durable_eventlog_shared.rs@origin/main`.

⚠ **But that is a different stack from the one the tier read traverses.** The
tier goes `tier_store::driver()` → `LocalReferenceEventLogDriver` →
`with_runtime` → `LocalReferenceRuntime { log: LocalJsonlTransactionLog, state:
ReferenceDatabase }` → `state().streams.replay_matching(...)`. **VERIFIED**
(`ehdb-reference/src/lib.rs:182-185`). The segment index sits on the durable
*segment* path; the tier's default read path is the `ReferenceDatabase` streams
store, where the `BTreeMap` + linear filter above still governs.

**ASSUMED:** that no configuration currently routes the tier's `read_execution`
through the indexed segment path. Trace this before relying on it — it is the
same "which path does prod actually take" question that has inverted twice in
this program.

### 1.5 Why executions stall, and why the re-drive exists

The causal chain, each link cited:

1. Advancing an execution needs its chain. Under the off-server drive the state
   builder builds a **spine** to an expected head and returns `Incomplete` when
   it cannot (**VERIFIED** — the #119 write-up records
   `build_spine_to(expected_head)` returning permanently `Incomplete` with
   `wal_events_total=0`).
2. A chain read that times out is indistinguishable from a chain that is
   genuinely short. The read returns empty; the drive concludes "not ready".
3. Not-ready schedules a re-drive. The server's own config comment states the
   consequence (**VERIFIED**, `server/src/config/app.rs:704-713`): *"a truncated
   event log left **53 executions whose WAL chain could never complete**, each
   re-driven every 8s with a freshly issued `__orchestrate__` command. The system
   pool sat at lag 78-86 and never drained, and a synthetic burst degraded from
   p50 199ms to **1997ms with 23 of 60 requests timing out**."*
4. Re-driving adds load to the same saturated tier, which makes the next chain
   read slower. **The loop is self-reinforcing.**

⭐ So the re-drive is not a scheduler feature. **It is a retry around a read that
should not have been able to fail.**

### 1.6 Why the give-up cap cannot fire

`NOETL_RECONCILE_MAX_NOOPS = 225` counts **poller iterations**, and its own doc
comment says *"the poller ticks every 8s, so that is ~30 minutes"* (**VERIFIED**,
`app.rs:704`). Measured on prod, the loop ticks at **~299 s** — two independent
signals over the same window each saw **1** tick where 8 s implies 37. So
**225 polls = 18.7 hours**, because the loop awaits every active execution's
drive sequentially and each drive pays §1.3.

⭐ **The cap's units are a copy of reality, not a property of the loop** — the
`representation-drift` failure class, in a constant. And three PRs (#461, #462,
#463) each correctly removed a real budget-reset path without the cap ever
becoming reachable, because the unreachability was never in the reset logic.

⚠ **This is the argument for redesign over patching.** A fourth patch to the cap
would be correct and still inert. The cap is bounding a loop that exists to
retry a read; fix the read and all three mechanisms lose their reason to exist.

---

## 2. The model — four ids, and what they buy

### 2.1 Formal statement (the owner's requirement)

For every event `e`:

```
e.event_id             : EventId            -- unique
e.parent_event_id      : Option<EventId>    -- exactly one, None only at a chain root
e.execution_id         : ExecutionId        -- exactly one; the CONTAINER and the PARTITION KEY
e.parent_execution_id  : Option<ExecutionId>-- exactly one, None only at a tree root
```

Invariants:

- **I1 — single-parent event chain.** Each event has at most one parent event.
  The chain is a path, not a DAG. No merge nodes, so a walk is deterministic.
- **I2 — containment.** `event_id` and `parent_event_id` both belong to exactly
  one `execution_id`; an event never spans executions.
- **I3 — execution tree.** `execution_id` has at most one
  `parent_execution_id`. Executions form a tree.
- **I4 — context completeness.** Every context carries **all four** ids.

⭐ **I4 is the load-bearing one, and it is easy to undersell.** It is what turns
finding the parent from a *search* into an *address*. If the reader must
discover the parent, any layout costs at least an index probe and, in today's
layout, a scan. If the reader is *told* `(parent_execution_id, parent_event_id)`,
the parent is a key it can compute without reading anything first.

### 2.2 Access patterns and honest complexity

Let `N` = total events in the store, `k` = events in one execution, `d` = depth
of the execution tree. Store is an **ordered key-value map** with composite key
`(execution_id, seq)` and a secondary point-addressable
`(execution_id, event_id)`.

| # | pattern | key used | cost | today |
| :-- | :-- | :-- | :-- | :-- |
| **A** | **find parent of an event** | `(e.parent_execution_id, e.parent_event_id)` | **one point lookup** | O(N) filter |
| **B1** | **append next event** | `(execution_id, seq+1)` | one write at the partition tail | one global-sequence append (already cheap) |
| **B2** | **read the execution's ordered chain** | range `(execution_id, 0) .. (execution_id, ∞)` | **O(log N + k)** — one seek, then `k` contiguous | **O(N)** filter |
| **C** | **navigate the execution tree** | `(parent_execution_id, ·)` per hop | **O(d) lookups**, each pattern A | O(N·d) |

**On the O(1) claim, precisely.** Pattern A is *one lookup, independent of N and
k* — that is the property that matters, and it follows from I4, not from the
storage engine. Whether that one lookup is literally O(1) depends on the index:
a hash index gives expected O(1); an LSM or B-tree gives O(log N) with a small
constant and, in practice, one-to-two block reads. **The honest formulation is
"one point lookup, no scan, no dependence on how much else exists"** — and the
distinction from today is not a constant factor, it is the difference between
touching one key and touching every key.

**On B2.** The `O(log N)` is the seek to the partition start; the `k` is the
execution's own events read contiguously. Contiguity is the point: today those
`k` records are scattered across the global sequence and interleaved with every
other execution's, so even a perfect index would still pay `k` random reads.
Keying by `(execution_id, seq)` makes them **physically adjacent**.

**Proof obligations** any candidate design must discharge, because each is a way
this could be true on paper and false in the store:

- **P1** — pattern A issues **exactly one** storage operation, verified by a
  counting substrate, not by reading the code.
- **P2** — pattern B2's cost is a function of `k` only. Measure with `k` fixed
  and `N` grown by ≥10×; the latency must not move. (This is the measurement
  today's store fails: §1.3's table shows latency independent of *result* size
  and dependent on *store* size — exactly inverted.)
- **P3** — append does not invalidate a reader's seek position on another
  partition (no global lock). §1.3's C-c is a live counter-example.

### 2.3 No SQL is needed, and that is not a limitation

Every pattern above is a point lookup or a single contiguous range scan on a
sorted composite key. There is no join, no predicate over non-key columns, no
aggregation, no planner decision. This is an **ordered KV workload**, and the
program invariant in
[`ehdb-layered-platform.md`](./ehdb-layered-platform.md) already forbids the
general-database direction. Adding SQL would add a planner whose only job would
be to rediscover the access path the four ids already name.

---

## 3. What already exists (do not rebuild it)

This program's recurring failure is building a component that already exists, so:

| piece | state | citation |
| :-- | :-- | :-- |
| `prev_event_id` **single-parent chain**, stamped at the `emit_events` chokepoint from a per-execution chain-head watermark | **IMPLEMENTED + kind-validated**, RFC #115 Phase 2, server#244 | `115-phase2-prev-event-chain` memory; `prev_event_id` in **14** server source files (**VERIFIED**) |
| `parent_event_id` | **exists and is NOT the chain pointer** — under the off-server drive it is the suppressed `__orchestrate__` trigger and would **dangle** if walked | 13 server files (**VERIFIED**); the #115 write-up says so explicitly |
| `parent_execution_id` | exists | 21 server files (**VERIFIED**) |
| chain-walk state builder (head→root, no event scan) | designed as #115 **Phase 3** | `115-phase2` memory |
| `noetl.event` retired from the hot read path | **COMPLETE**, server v3.36.0, `NOETL_EVENT_READ_PATH=audit_only` (default still `event_scan`) | `115-phase6-event-read-path` |
| L0 partitions by `shard_for(execution_id)` with a **per-part bloom over `execution_id`** | implemented | `ehdb-l0/src/dataset.rs`, `lib.rs` L0.2 (**VERIFIED** earlier this program) |
| tier does **not** run on `ehdb-l0` | **VERIFIED** — `ehdb-reference` has no `ehdb-l0` dependency | multi-region plan §0 |

⚠⚠ **The most important row is the second.** The owner's model names
`parent_event_id` as the chain pointer. In this codebase `parent_event_id` is a
*causal trigger* pointer that is known to dangle, and the *chain* pointer is
`prev_event_id`. **Implementing the model against `parent_event_id` would walk
into a dangling pointer on exactly the off-server path that is failing.**

**Recommendation (fork F1):** keep two distinct relations and name them
separately — `prev_event_id` for the chain (I1, walkable, the thing this RFC
makes fast) and `parent_event_id` for causality (an attribute, not a traversal
edge). Do not unify them; the unification is what would dangle.

---

## 4. Options evaluated

### 4.1 Cloudflare Durable Objects — reference model, not a candidate

Each object is a **single-threaded, globally unique instance that serialises
access to its own durable storage**, giving **strict serializability** and
global ordering of requests and storage operations; storage is now SQLite-backed
(GA, 10 GB per object on Workers Paid, new namespaces must use it).

One DO per `execution_id` is *exactly* the model in §2: a per-execution
single-writer partition with an ordered local log and local reads.

⛔ **Not runnable as the GKE backend.** Workers/edge only. Treating it as a
candidate would be a category error.

✅ **Where it legitimately fits:** the console/edge surfaces — the waitlist KV we
already use, edge session state, per-user UI coordination. And as the **design
authority for the partition shape**: "one writer per execution, ordered local
log" is the property to reproduce natively.

### 4.2 Cloudflare KV / D1 / R2 — edge roles only

| product | shape | role here |
| :-- | :-- | :-- |
| **KV** | eventually consistent, cached reads | already used (waitlist). ⛔ Eventual consistency is disqualifying for a chain whose reader must not see a gap |
| **D1** | SQL, single-region strong | ⛔ SQL we do not want (§2.3), single-region, edge-oriented |
| **R2** | object store | plausible **substrate** under L0 later (§6), not an event store |

### 4.3 NATS JetStream — **the seeded framing does not survive research**

The seed proposes a stream or subject per `execution_id`, with the monotonic
sequence as the chain and JetStream KV for the parent index. Ordering,
retention, replay and dedupe are all genuinely good, and it is GKE-runnable.

⚠⚠ **But `execution_id` is unbounded-cardinality, and per-entity subjects are
the documented JetStream antipattern.** Synadia's own guidance: *"the single most
common subject-design mistake is encoding high-cardinality, per-message data
into the subject itself"*; the server's in-memory subject index grows linearly,
so *"a stream with 10 million unique subjects can consume gigabytes of RAM just
for the index, independent of message payload"*; and *"adding more than a few
hundred disjoint subject filters will likely lead to slowness and instability."*
A stream per execution is worse still — streams are far heavier than subjects.

⚠ **And it reverses a locked decision.** NATS was **deleted** from this platform
at T5. Re-introducing it as the system of record would reverse that, reintroduce
an external service with its own quorum and lifecycle, and contradict
[`self-sufficiency.md`](../../agents/rules/self-sufficiency.md) — which forbids
an external *datastore* while welcoming libraries.

**Verdict: reject** as the event store. Retained as prior art for per-subject
ordering and for the "KV built on a stream" latest-pointer idiom, which §5's
recommendation reuses natively.

### 4.4 CockroachDB's distributed KV layer — right shape, wrong weight

The layer under the SQL is precisely §2's model: a **sorted map** sharded into
**ranges** (512 MiB default), each replicated by **Raft** (3× by default), with
the SQL layer sitting on top as a separate concern. Key `(execution_id, seq)`
would land contiguously; ranges would split by `execution_id` naturally.

Honest assessment:

- ✅ Ordering, contiguity, partitioning and multi-region placement are all first
  class and battle-tested.
- ⛔ **It is an external database** — the one thing `self-sufficiency.md` names.
- ⛔ **Raft under every write** is the cost the EHDB program explicitly retired:
  `ehdb-l0/src/lib.rs:85` says *"no consensus / no Raft — the HDFS /
  block-replication model, not a replicated log"*, because immutable parts never
  conflict. Adopting Cockroach's KV would re-adopt consensus for a workload that
  demonstrably does not need it.
- ⛔ There is no supported way to take the KV layer *without* the SQL layer.
  "Use the KV under Cockroach" is not a packaging that exists.
- ⛔ Write amplification: every write is logged twice (storage WAL + Raft log).

**Verdict: reject.** Adopt its **key design** (`(execution_id, seq)` in a sorted
map, ranges as shards), not its implementation.

### 4.5 Native EHDB restructure — **recommended**

Repartition the event log so `execution_id` is the physical partition and the
chain is contiguous within it, and replace chain *reconstruction* with chain
*following*.

The reason this is the incremental path and not a rewrite: **most of it already
exists in `ehdb-l0` and is simply not on the tier's path.** L0 already has
immutable parts, a manifest, a sparse index, `partition = shard_for(execution_id)`,
and a per-part bloom over `execution_id`. What it lacks for §2 is (i) a sort key
that is per-execution rather than global, and (ii) a point-addressable parent
index. What the *tier* lacks is L0 at all.

---

## 5. Comparison matrix

Scored against §2's patterns. **A** = O(1)-style parent lookup, **B2** =
per-execution contiguous chain read, **C** = tree navigation.

| | Durable Objects | CF KV | D1 | JetStream | Cockroach KV | **Native EHDB** |
| :-- | :-- | :-- | :-- | :-- | :-- | :-- |
| **A — parent lookup, no scan** | ✅ local | ⚠ eventual | ✅ | ⚠ needs a side KV | ✅ | ✅ *(to build)* |
| **B2 — contiguous per-execution chain** | ✅ native | ❌ | ⚠ via SQL | ✅ per subject | ✅ | ✅ *(to build)* |
| **C — execution-tree navigation** | ⚠ cross-object hop | ❌ | ✅ | ⚠ | ✅ | ✅ |
| **Partition key = `execution_id`** | ✅ intrinsic | ⚠ key prefix | ❌ | ⚠ antipattern at cardinality | ✅ ranges | ✅ *(already `shard_for`)* |
| **Consistency for a chain reader** | strict serializable | eventual | strong 1-region | per-subject ordered | serializable | single-writer per shard |
| **Ordering guarantee** | total per object | none | txn | per subject | per range | per partition |
| **GKE-runnable as backend** | ❌ edge only | ❌ | ❌ | ✅ | ✅ | ✅ |
| **External service to operate** | n/a | n/a | n/a | ❌ yes | ❌ yes | ✅ none |
| **Honors `self-sufficiency.md`** | n/a | n/a | n/a | ❌ | ❌ | ✅ |
| **Reverses a locked decision** | — | — | — | ❌ NATS deletion (T5) | — | — |
| **Consensus on the write path** | internal | — | — | RAFT (R>1) | Raft always | none (immutable parts) |
| **Ops cost** | low (managed) | low | low | medium-high | **high** | medium |
| **Migration risk** | n/a | n/a | n/a | high | very high | **medium, and incremental** |
| **Verdict** | **reference model** | edge role | edge role | reject | reject (adopt key design) | ⭐ **recommend** |

---

## 6. Recommended design — L0-backed, execution-partitioned

### 6.1 The physical model

```
partition   = shard_for(execution_id)          -- already exists, XxHash64 seed 0
sort key    = (execution_id, exec_seq)         -- CHANGED: per-execution, not global
point index = (execution_id, event_id) -> offset
chain edge  = prev_event_id                    -- I1, already stamped (#115 Ph.2)
tree edge   = parent_execution_id              -- I3, already carried
```

Four concrete changes, in dependency order:

**R1 — put the tier on L0.** The tier currently serves from
`ReferenceDatabase`'s `BTreeMap` (§1.2). Until it is L0-backed, every
partitioning improvement is inert on the path that matters. ⭐ **This is already
specified as M0.5 in the multi-region plan** (`NOETL_EHDB_TIER_BACKEND`,
default `local_reference`) and is already implemented as a refusing scaffold on
`worker@feat/mr-cluster-b`. This RFC and the multi-region plan **share their
first phase.**

**R2 — make the sort key per-execution.** L0's D1 sort key is `global_sequence`
(`ehdb-l0/src/dataset.rs`). Add an `exec_seq` and sort `(execution_id, exec_seq)`
within a partition, so an execution's events are **physically contiguous** and
B2 is a single range read. `global_sequence` stays as the append-order attribute
— it is still the mirror/parity key and must not be removed.

**R3 — add the point index.** `(execution_id, event_id) → offset` per part, so
pattern A is one lookup. The per-part bloom over `execution_id` already prunes
parts; this makes the within-part step a probe rather than a scan.

**R4 — replace reconstruction with following.** The state builder walks
`prev_event_id` head→root over R2/R3 instead of rebuilding from a scan — RFC
#115 **Phase 3**, which was designed for this and never shipped. A chain read
that is O(k) cannot time out the way a chain read that is O(N) does, which is
what removes the re-drive's reason to exist.

### 6.2 Why this kills the re-drive rather than tuning it

| today | after |
| :-- | :-- |
| chain read is O(N), times out at 2 s | chain read is O(log N + k) |
| timeout is indistinguishable from "chain short" | a missing link is a **distinguishable, reportable** absence at a known key |
| not-ready ⇒ re-drive ⇒ more tier load ⇒ slower reads | no retry loop on the read path |
| a cap is needed to bound the loop | **no loop to bound** |
| the cap counts polls at the wrong rate | the cap and its units are deleted |

⭐ The invariant to hold: **a chain gap must be a first-class, named error at a
specific `(execution_id, event_id)`**, never an empty result. An empty result is
what makes a timeout look like progress and a truncation look like completion —
and it is why 53 executions could re-drive forever without anything saying why.

### 6.3 What must NOT change

- `noetl.event` stays **append-only / immutable**; replay stays the source of
  truth. This is a read-path redesign.
- `global_sequence` stays. The parity comparators and the mirror key off it.
- No SQL layer, ever (§2.3, and the layered-platform invariant).
- Single writer per shard. R2 makes contiguity depend on it *more*, not less —
  which is why fencing (M5) is a prerequisite for anything that moves writers.

---

## 7. Composition with the multi-region plan

The alignment is not a coincidence: both designs chose `execution_id` as the
partition key, for different reasons that turn out to be the same reason.

| multi-region axis | this RFC |
| :-- | :-- |
| **shard** = `shard_for(execution_id)` | the same function, unchanged — one partition function, not two |
| **region** (M1 `Locality`, M4 survival goals) | a partition is the unit placed in a region. An execution's chain is **local to one partition**, so a chain read is a single-region read even in a multi-region deployment |
| **M0.5 tier-backend** | **the shared first phase** — R1 *is* M0.5 |
| **M3 closed timestamps** | a per-execution chain gives a per-partition closed timestamp, which is a tighter and more meaningful bound than a global one |
| **M6 follower reads** | pattern B2 becomes servable from a non-leader replica once the chain is contiguous and a closed timestamp exists |
| **M5 fencing** | prerequisite for both. Contiguity within a partition assumes one writer |
| **HLC (M2)** | `exec_seq` is the *intra-execution* order; HLC remains the *cross-partition* comparison. They are complementary — do not collapse them, for the same reason `global_sequence` is not a global order |

⭐ **The convergence to state plainly:** the multi-region plan needed
`execution_id` as a placement key; this RFC needs it as a retrieval key. One
repartition serves both, and doing them separately would mean partitioning the
same log twice.

---

## 8. Phased migration — retiring reconcile/re-drive

Every phase behind its own flag, default off/shadow, additive on disk, kind
before prod, RED→GREEN with a planted defect, comparator-green + rollback. Order
chosen so no phase can break an existing feature.

| phase | what | flag | exit criterion | retires |
| :-- | :-- | :-- | :-- | :-- |
| **E0** | **Instrument the real cost.** Publish per-read `records_scanned` vs `records_returned` and the per-store mutex wait, on the live tier path | none (metrics, pinned at 0) | The ratio is published and the scanned/returned gap is **measured**, not inferred. ⚠ Must be on the path §1.4 flags as ASSUMED — trace it first | — |
| **E1** | **R1** — tier served by L0 | `NOETL_EHDB_TIER_BACKEND=l0` | byte-identical outcome under the default; cross-backend read **refused**, not misparsed | — |
| **E2** | **R2** — `(execution_id, exec_seq)` sort key, written in **shadow** beside `global_sequence` | `NOETL_EHDB_EXEC_SEQ=off\|shadow\|on` | 100 % of new records carry `exec_seq`; rollback binary reads them (expand-first, tolerate **before** write); `global_sequence` untouched | — |
| **E3** | **R3** — point index `(execution_id, event_id)` | `NOETL_EHDB_EXEC_INDEX` | **P1**: pattern A issues exactly one storage op, proven with a counting substrate. **P2**: B2 latency flat as `N` grows 10× at fixed `k` | — |
| **E4** | **R4** — chain-following state builder (#115 Phase 3) behind a flag, compared against the scan builder on a fixed population | `NOETL_CHAIN_WALK_BUILDER` | identical spine for ≥ N executions; a chain gap reports a **named error at a specific key**, never empty | — |
| **E5** | **Stop re-driving on read-not-ready.** Re-drive only on a *distinguishable* incomplete chain | `NOETL_RECONCILE_ON_READ_FAIL=off` | `offserver_retry` rate drops to the rate of real incompleteness; measured, with a prediction made first | the retry loop |
| **E6** | **Delete the cap and its units.** Remove `NOETL_RECONCILE_MAX_NOOPS`, the budget, the tombstones and the give-up metric | — (deletion) | no execution re-drives without a named cause; `giveup` series removed rather than left reading 0 | **#461/#462/#463 line, the 225 cap, the 18.7 h** |
| **E7** | Retire the `event_scan` read path default (flip `NOETL_EVENT_READ_PATH` to `audit_only`) | existing flag | already COMPLETE as code; this is the default flip | the last hot-path scan class |

⚠ **E6 is the point of the RFC and must not be skipped for being unglamorous.**
A cap left in place "just in case" would sit at 0 forever and be read as
evidence that nothing is stalling — a metric that cannot fire, which is this
program's most repeated defect. If E5 is right, E6 is mandatory; if E6 feels
risky, E5 is not finished.

⭐ **E0 first, deliberately.** The §1.3 table is from #155 and a 161.7 MB store;
prod is far larger and the cache is now on. Re-measuring before restructuring is
the difference between fixing the bottleneck and fixing last quarter's
bottleneck — and E0's `scanned/returned` ratio is the number that proves the
diagnosis on today's prod rather than on a doc comment.

---

## 9. Open forks — recommended defaults, none blocking

- **F1 — chain pointer: `prev_event_id` vs `parent_event_id`.** ⭐ **Keep both,
  separately.** `prev_event_id` is the walkable chain (I1); `parent_event_id`
  is causal provenance and is known to dangle under the off-server drive.
  Unifying them implements the model against a dangling pointer on the exact
  path that is failing. Revisit only with a measurement showing
  `parent_event_id` never dangles.
- **F2 — partition granularity: one partition per `execution_id`, or a hash
  bucket of it?** ⭐ **Hash bucket** (`shard_for(execution_id)`, already in
  use). One partition per execution would give perfect locality and reproduce
  the JetStream cardinality failure at the file level — unbounded partitions,
  unbounded open handles, an index that grows with executions rather than with
  data. Bucketing keeps contiguity *within* a bucket while bounding partition
  count. Revisit if a hot bucket is measured.
- **F3 — `exec_seq` source.** ⭐ **Assigned by the partition's single writer**,
  like `global_sequence`. Deriving it from the chain depth would make it
  unavailable until the parent is read, which is the dependency this whole RFC
  removes.
- **F4 — tree navigation: pointer-per-hop or a materialised ancestor path?**
  ⭐ **Pointer-per-hop (O(d)).** `d` is small in practice; a materialised path
  is a denormalisation that must be kept true, and this program has a frozen
  column (`noetl.execution.status`) as the standing example of what happens
  when derivable state is also stored.
- **F5 — migrate existing data, or forward-only?** ⭐ **Forward-only, with the
  old path retained for reads of old executions.** A backfill of the log is a
  write to an append-only immutable store; the repair history in
  [#343](https://github.com/noetl/ai-meta/issues/343)/[#345](https://github.com/noetl/ai-meta/issues/345)
  is that a repair closed a count gap and opened a content one. New executions
  get the new layout; old ones age out under retention.
- **F6 — does the segment `.idx` path already cover the tier read?** Marked
  **ASSUMED** in §1.4 and it changes E0/E1's scope if true. ⭐ **Trace it before
  E1**, with a counting substrate rather than by reading the code.

---

## 10. Summary

1. The store is **ordered globally and partitioned by nothing**, so the two
   operations event sourcing does most — find the previous record, read an
   execution's chain — are both **O(total store)**. The code documents this and
   measures it: `read_execution` returning 92 KB took **858 ms**, and *"the
   latency does not track the result size… it is the replay in front of it."*
2. The **re-drive is a retry around that read**, and the **cap is a bound on the
   retry**. The cap counts polls on a loop measured at **~299 s/tick**, so
   `225 = 18.7 h`. Three correct patches (#461/#462/#463) could not make an
   unreachable cap reachable.
3. The owner's **four-id model** fixes it at the root: I4 (context carries all
   four ids) turns find-parent from a search into an **address**, and
   `execution_id` as partition key makes a chain **physically contiguous**.
4. **Durable Objects is the right reference model and not a candidate**
   (edge-only). **JetStream is rejected** — per-execution subjects are the
   documented cardinality antipattern and it reverses the T5 NATS deletion.
   **Cockroach KV is rejected** — right key design, but an external database with
   Raft on every write, which L0 explicitly retired.
5. **Recommend the native restructure**: tier on L0, sort key
   `(execution_id, exec_seq)`, a point index for the parent, and chain-*following*
   instead of chain-*reconstruction*.
6. It **shares its first phase with the multi-region plan** (M0.5 = R1) and its
   partition function with M1/M4. One repartition serves placement and retrieval.
7. The migration ends by **deleting** the cap, the budget, the tombstones and the
   give-up metric — not by tuning them.

## Sources

Prior art consulted for §4 (external, September 2026):

- [JetStream Anti-Patterns — Synadia](https://www.synadia.com/blog/jetstream-design-patterns-for-scale)
- [NATS Subject Count Threshold — Synadia](https://www.synadia.com/insights/checks/nats-subject-count-threshold)
- [Designing NATS Subject Hierarchies — Synadia](https://www.synadia.com/blog/designing-nats-subject-hierarchies)
- [Streams — NATS Docs](https://docs.nats.io/nats-concepts/jetstream/streams)
- [SQLite-backed Durable Object Storage — Cloudflare](https://developers.cloudflare.com/durable-objects/api/sqlite-storage-api/)
- [Durable Objects limits — Cloudflare](https://developers.cloudflare.com/durable-objects/platform/limits/)
- [Choosing a data or storage product — Cloudflare Workers](https://developers.cloudflare.com/workers/platform/storage-options/)
- [Range / Shard — Cockroach Labs](https://www.cockroachlabs.com/glossary/distributed-db/range-shard/)
- [Replication Layer — CockroachDB](https://docs.cockroachlabs.com/docs/stable/architecture/replication-layer)
- [CockroachDB design.md](https://github.com/cockroachdb/cockroach/blob/master/docs/design.md)
