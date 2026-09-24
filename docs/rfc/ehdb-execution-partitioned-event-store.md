# RFC: Execution-partitioned event store — retire reconcile/re-drive

**Status:** RFC — design only. **No prod change, no code change, nothing merged.**
**Date:** 2026-09-24 (revised same day with the owner's consistency constraint).
**Owner constraints, treated as requirements:** the four-id model (§2.1) and
**geographically distributed executions with eventually-consistent storage
across replicas** (§2.4) — strong ordering only *within* an `execution_id`
partition.
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

### 2.4 The consistency model — strong where it is local, eventual everywhere else

**Owner constraint (2026-09-24), and it is a requirement, not a preference:**

> **Executions can be geographically distributed, but storage is EVENTUALLY
> CONSISTENT across replicas — not globally strongly consistent.**

This splits the consistency budget along the partition boundary, which is the
same boundary §2.2 already drew for performance:

| scope | guarantee | why it is needed there |
| :-- | :-- | :-- |
| **Within one `execution_id` partition** | **single writer / leader; strict append order** | I1's chain is a path. Two concurrent appenders could both claim `prev = e`, which forks it. This is the *only* place strong ordering is required |
| **Across replicas of a partition** | **eventual** — async catch-up | A reader elsewhere may see a shorter tail. Nothing about the chain's correctness depends on it being current |
| **Across different executions** | **none required** | Executions are independent partitions. Cross-execution ordering is a cross-partition question, answered by the HLC (M2) when anyone asks it, and by nothing otherwise |

**Execution homing.** Each `execution_id` has a **home region**, where its
partition's writer lives. "Geographically distributed executions" therefore
means *different executions homed in different regions*, each its own
single-writer partition, replicated outward asynchronously. It does **not** mean
one execution's chain being written from two places — that is the one thing the
model forbids.

⭐ **The reason this is worth stating as its own section:** it means the
expensive guarantee (global strong consistency) is not merely unnecessary — it
is **actively unwanted**, because paying for it costs cross-region consensus
latency on every append to buy a property the chain does not use. §4.4 and §5
are re-scored on that basis.

### 2.5 Why eventual replication is safe here — the non-divergence proof

The owner asks for this proved rather than asserted, and it turns out to need
**two** properties at two different strengths. Conflating them would overstate
the guarantee.

**Setup.** Execution `E` has home partition `P(E)` with exactly one writer at
any instant. Events `e₀, e₁, …` are appended in order, `eᵢ₊₁.prev = eᵢ.event_id`,
`e₀.prev = None`. Replication ships the log to replicas asynchronously.

#### Property N — Non-divergence (the safety property)

> **No replica, at any time, can observe a forked chain.** Specifically: no
> reader ever sees two distinct events claiming the same parent, and never sees
> an event whose parent pointer disagrees with what another replica reports for
> the same event.

*Proof.*

1. **Unique successor.** A single writer serialises appends to `P(E)`, so for
   any event `e` there is **at most one** event `e'` with `e'.prev = e.event_id`.
   Two appenders could each write a successor to `e`; one appender cannot.
2. **Immutability.** `noetl.event` is append-only and an event never mutates
   (§6.3). So `e.prev` has exactly one value for all time, and every replica
   that holds `e` holds the same `e`.
3. **Replication is subset-only.** Async replication delivers events the writer
   wrote; it never synthesises, reorders *within* a record, or edits one.
4. From (1)–(3), the set visible at any replica is a **subset of one fixed
   path**, and every visible edge agrees with the authoritative edge. A fork
   requires either two successors (excluded by 1) or a changed pointer
   (excluded by 2). ∎

⚠ **Property N depends on (1), which is exactly what fencing enforces.** Today
single-writer rests on `replicas: 1` — an orchestration preference, not a
mutual-exclusion primitive. **So the safety of the eventual model is
conditional on M5 (fencing `Enforce`)**, and that dependency should be recorded
rather than assumed: without it, a partitioned old writer appending a second
successor to `e` is precisely the fork this proof excludes.

#### Property P — Prefix (the liveness/usability property) — weaker, and conditional

> A replica's visible set is a **prefix** of the chain, not merely a subset.

This does **not** follow from N. A subset of a path can have holes: delivery of
`e₀, e₁, e₃` leaves a reader unable to walk past `e₁`. Prefix-ness requires
**per-partition ordered delivery** — the replication stream for `P(E)` must
preserve append order. A log-shipping mirror does; an unordered fan-out does
not.

**Recommendation:** require per-partition ordered replication so P holds, and
**do not rely on it for correctness** — N is the safety property and stands
without it.

#### ⭐ Why the chain is *self-verifying* under eventual replication

This is the part that makes the redesign and the eventual model fit each other
rather than merely coexist:

- Under a **global-sequence** log, a reader in region B that is missing
  sequence 100 cannot tell whether 100 is *not yet replicated* or *belongs to
  some other execution*. The gap is indistinguishable from irrelevance, so
  staleness is undetectable — which is exactly how a timed-out read became
  "chain short" in §1.5.
- Under a **per-execution chain**, the `prev` pointer **names the missing key**.
  A reader walking `E` that cannot resolve `eᵢ.prev` knows precisely which
  `(execution_id, event_id)` it is waiting for.

So the chain pointer *is* the gap detector. That converts staleness from a
silent condition into a **named, reportable one at a specific key** — the same
invariant §6.2 requires, arriving here for free. A reader can then legitimately
choose: wait, serve a bounded-stale prefix, or report the gap. All three are
safe; none of them is "empty result, assume done".

**Consequence for reads.** A cross-region read is a **bounded-staleness read**
(M3) against a replica whose **closed timestamp** bounds how far behind it is,
and M3's rule already applies: a request whose freshness cannot be satisfied is
**refused, not silently served stale**.

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

⭐ **Under §2.4 the fit is even closer than it first looks.** A DO is strongly
serializable **within** an object and has **no** cross-object consistency
guarantee at all — strong locally, nothing globally. That is §2.4's split
exactly, arrived at independently by a different team for a different reason.
It is the strongest external evidence that the shape is right; it remains
unrunnable on GKE.

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

**Verdict: reject** as the event store — the cardinality objection is about the
**store**, and §2.4 does not soften it.

⭐ **But §2.4 does rehabilitate one half of JetStream, and it should be said
plainly:** JetStream's **source / mirror streams** are a correct and
well-proven implementation of exactly the replication shape §2.4 asks for —
async, per-stream ordered (so Property P holds), catch-up-based, with the origin
remaining the single writer. That is the right *replication* model even though
the per-execution *subject* model is the wrong storage model.

The relevant fact is that **NoETL already has this**: the EHDB async mirror
(`ASYNC=true`, `SOURCE=server`, bounded `LAG_TOLERANCE`) plus M3
bounded-staleness reads are the same design. So the conclusion is not "adopt
JetStream for replication" — it is "the replication half of the recommendation
is a known-good pattern, and we are already running our own version of it."
Prior art, not a dependency.

### 4.4 CockroachDB's distributed KV layer — right shape, wrong weight

The layer under the SQL is precisely §2's model: a **sorted map** sharded into
**ranges** (512 MiB default), each replicated by **Raft** (3× by default), with
the SQL layer sitting on top as a separate concern. Key `(execution_id, seq)`
would land contiguously; ranges would split by `execution_id` naturally.

Honest assessment:

- ✅ Ordering, contiguity, partitioning and multi-region placement are all first
  class and battle-tested.
- ⛔⛔ **Its headline guarantee is now a COST, not a benefit.** Cockroach gives
  serializable transactions over Raft-replicated ranges — **globally strong
  consistency**. §2.4 says we want strong ordering *only within a partition* and
  **eventual** across replicas. Buying global strong consistency means paying
  **consensus on every append** — and, when a range's replicas span regions,
  **cross-region round trips on the write path** — to purchase a property the
  chain provably does not use (§2.5 Property N holds from single-writer plus
  immutability alone). This is the clearest case in the matrix of over-buying:
  the expensive guarantee is not merely surplus, it is a latency tax on the
  hot path of every event.
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
per-execution contiguous chain read, **C** = tree navigation. The consistency
rows are scored against **§2.4** — strong *within* a partition, **eventual**
across replicas — so a stronger guarantee than that is marked as the cost it is.

| | Durable Objects | CF KV | D1 | JetStream | Cockroach KV | **Native EHDB** |
| :-- | :-- | :-- | :-- | :-- | :-- | :-- |
| **A — parent lookup, no scan** | ✅ local | ⚠ eventual | ✅ | ⚠ needs a side KV | ✅ | ✅ *(to build)* |
| **B2 — contiguous per-execution chain** | ✅ native | ❌ | ⚠ via SQL | ✅ per subject | ✅ | ✅ *(to build)* |
| **C — execution-tree navigation** | ⚠ cross-object hop | ❌ | ✅ | ⚠ | ✅ | ⚠ cross-region hop (F7) |
| **Partition key = `execution_id`** | ✅ intrinsic | ⚠ key prefix | ❌ | ⚠ antipattern at cardinality | ✅ ranges | ✅ *(already `shard_for`)* |
| **Single writer per partition (§2.5 N)** | ✅ intrinsic | ❌ none | ❌ | ✅ per stream origin | ⚠ leaseholder, but via consensus | ✅ *(needs M5)* |
| **Consistency MATCH to §2.4** | ⭐ **exact** — strong per object, none across | ❌ too weak | ⚠ wrong axis | ✅ close | ⛔ **too strong = cost** | ⭐ **exact by construction** |
| **Cross-replica model** | n/a (single instance) | eventual | replicas | ⭐ async source/mirror, ordered | synchronous Raft | ⭐ async mirror + bounded staleness *(exists)* |
| **Pays consensus per append** | internal, local | — | — | only at R>1 | ⛔ **always, cross-region if ranges span** | ✅ **never** |
| **Ordering guarantee** | total per object | none | txn | per subject | per range | per partition |
| **GKE-runnable as backend** | ❌ edge only | ❌ | ❌ | ✅ | ✅ | ✅ |
| **External service to operate** | n/a | n/a | n/a | ❌ yes | ❌ yes | ✅ none |
| **Honors `self-sufficiency.md`** | n/a | n/a | n/a | ❌ | ❌ | ✅ |
| **Reverses a locked decision** | — | — | — | ❌ NATS deletion (T5) | — | — |
| **Ops cost** | low (managed) | low | low | medium-high | **high** | medium |
| **Migration risk** | n/a | n/a | n/a | high | very high | **medium, and incremental** |
| **Verdict** | **reference model** *(right shape, edge-only)* | edge role | edge role | reject as store; ⭐ **prior art for the mirror** | ⛔ reject — **over-buys consistency**; adopt key design only | ⭐ **recommend** |

**How §2.4 changed this matrix.** Before the constraint, Cockroach's
serializability read as its strongest column and the native option's
"single-writer per shard, eventual across" read as the weaker one. Under §2.4
they swap: the native model's consistency is an **exact match** and Cockroach's
is an over-buy paid on every append. The constraint did not merely reinforce the
existing recommendation — **it moved the second-place option to last on the axis
that used to be its best.**

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

**R5 — home each execution, and record the homing.** An `execution_id` gets a
**home region** at creation, carried as an attribute of the execution (not of
each event — it is a property of the partition). Writes for `E` go to `P(E)`'s
leader in its home region; reads may be served anywhere under R6. Homing is what
makes "geographically distributed executions" mean *many single-writer
partitions in many regions* rather than *one chain written from two places*.

⚠ Homing needs a **placement decision at execution creation** and a **record of
it that readers can resolve**. The natural home for that record is D8
(`RuntimeDataset`) plus the M1 `Locality` type — both of which already exist.
Do not invent a second topology store; the multi-region plan already settled
that topology lives in EHDB as D8.

**R6 — replicate per-partition, ordered, asynchronously.** Ship each partition's
log to its replicas in **append order** (Property P, §2.5), asynchronously, with
the origin remaining the sole writer. Cross-region reads are
**bounded-staleness** reads (M3) gated on the replica's closed timestamp.

⭐ This is not new machinery: the EHDB async mirror (`ASYNC=true`,
`SOURCE=server`, bounded `LAG_TOLERANCE=30s`) plus M3 is the same design. R6 is
mostly **repointing the existing mirror at partitions instead of at a global
log** — which is the same change R2 makes to the sort key, one layer up.

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

⭐⭐ **Under §2.4 this invariant does double duty, and that is the tidiest result
in this RFC.** The same named-gap requirement that removes the re-drive is also
what makes eventual cross-region replication *safe to read from*: a region-B
reader that is behind sees a gap **at a named key** (§2.5) and can wait, serve a
bounded-stale prefix, or report it. One invariant, two problems — the local
staleness that caused the stall, and the remote staleness the owner is asking us
to accept deliberately.

### 6.3 What must NOT change

- `noetl.event` stays **append-only / immutable**; replay stays the source of
  truth. This is a read-path redesign.
- `global_sequence` stays. The parity comparators and the mirror key off it.
- No SQL layer, ever (§2.3, and the layered-platform invariant).
- **Single writer per partition.** R2 makes contiguity depend on it *more*, not
  less — and §2.5 Property N makes **correctness under eventual replication**
  depend on it outright. Fencing (M5) is therefore a prerequisite for the
  eventual model, not only for moving writers. ⚠ This is the one place where
  "eventual consistency is cheaper" is false: it is cheaper in *replication*
  and it raises the bar on *exclusion*.
- **No cross-region write path for a single execution.** An execution is homed
  (R5). Two regions appending to one chain is the fork §2.5 excludes.

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

### 7.1 ⭐⭐ §2.4 largely dissolves the M8 / F2b problem

The multi-region plan's hardest open fork was **F2b — the lease authority under
region failure**: the Kubernetes Lease CAS that elects a writer is per-cluster,
so losing the region hosting it means no writer can be elected anywhere. That
fork gated **M8 (region-survivable writes)**, and the plan's honest position was
*"reads reach REGION, writes stay ZONE."*

**Under §2.4 that is no longer a limitation to apologise for — it is the
intended design.**

Because every execution is **homed** (R5) and no execution's chain is ever
written from two regions (§2.5), losing a region does not leave a chain
un-writable-but-needed. It means:

- the **in-flight executions homed there** stop advancing and must be retried as
  **new executions** (a new `execution_id`, homed elsewhere) — which is a
  scheduling concern, not a storage-consistency one;
- **every other region keeps writing its own executions**, unaffected, because
  they were never sharing a writer;
- **all replicated data remains readable** everywhere, at bounded staleness.

So the thing M8 was going to buy — moving a *specific* execution's writer to
another region — is **not required for availability**. New work is homed
elsewhere immediately; only the executions mid-flight in the lost region are
affected, and those need a *retry policy*, not cross-region write failover.

**Recommendation: keep M8 `off`, and re-scope it from "needed" to "optional."**
⚠ Two honest caveats, because this is a de-scope and de-scopes are where
optimism hides:

1. It converts a **consistency** problem into a **scheduling** problem. Someone
   must decide what happens to executions orphaned in a lost region — retry as
   new, or leave them for the region's return. That decision does not exist yet
   and should be written down before anyone calls M8 unnecessary.
2. An execution whose **parent** is homed in the lost region is reachable only at
   the staleness the last replication left — see fork **F7**.

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
| **E2b** | **R5** — home each execution; record the home in D8 + `Locality`. Written and readable, **consulted by nothing** | `NOETL_EHDB_EXEC_HOMING=off\|shadow\|on` | 100 % of new executions carry a home; resolvable by a reader; routing unchanged | — |
| **E3** | **R3** — point index `(execution_id, event_id)` | `NOETL_EHDB_EXEC_INDEX` | **P1**: pattern A issues exactly one storage op, proven with a counting substrate. **P2**: B2 latency flat as `N` grows 10× at fixed `k` | — |
| **E4** | **R4** — chain-following state builder (#115 Phase 3) behind a flag, compared against the scan builder on a fixed population | `NOETL_CHAIN_WALK_BUILDER` | identical spine for ≥ N executions; a chain gap reports a **named error at a specific key**, never empty | — |
| **E4b** | **R6** — repoint the async mirror at **partitions**, ordered per partition (Property P). Cross-region reads gated on M3 closed timestamps | `NOETL_EHDB_MIRROR_SCOPE=global\|partition` | per-partition order preserved end-to-end, **proven with an out-of-order injection** (a mirror that reorders must fail this, or P is untested); a behind replica reports a **named gap**, never an empty chain | — |
| **E5** | **Stop re-driving on read-not-ready.** Re-drive only on a *distinguishable* incomplete chain | `NOETL_RECONCILE_ON_READ_FAIL=off` | `offserver_retry` rate drops to the rate of real incompleteness; measured, with a prediction made first | the retry loop |
| **E6** | **Delete the cap and its units.** Remove `NOETL_RECONCILE_MAX_NOOPS`, the budget, the tombstones and the give-up metric | — (deletion) | no execution re-drives without a named cause; `giveup` series removed rather than left reading 0 | **#461/#462/#463 line, the 225 cap, the 18.7 h** |
| **E7** | Retire the `event_scan` read path default (flip `NOETL_EVENT_READ_PATH` to `audit_only`) | existing flag | already COMPLETE as code; this is the default flip | the last hot-path scan class |

⚠ **E6 is the point of the RFC and must not be skipped for being unglamorous.**
A cap left in place "just in case" would sit at 0 forever and be read as
evidence that nothing is stalling — a metric that cannot fire, which is this
program's most repeated defect. If E5 is right, E6 is mandatory; if E6 feels
risky, E5 is not finished.

⚠⚠ **E2b and E4b are where §2.4 lands, and their exit criteria are deliberately
adversarial.** E4b's is not "replication works" but *"an injected reordering
fails the check"* — because Property P is precisely the kind of guarantee that
holds by accident in a quiet test and is never exercised. A mirror that happens
to preserve order under low load, untested against reordering, is an assumption
wearing a green check.

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
- **F7 — cross-region execution-tree navigation.** §2.4 allows a parent execution
  homed in region A and a child in region B, so pattern C (§2.2) can cross
  regions — and under eventual consistency the parent may be stale or, briefly,
  absent at the child's replica. Options: (a) synchronous cross-region read of
  the parent; (b) **the child carries the parent context it needs, denormalised
  at creation**; (c) tree walks are bounded-staleness reads that can report a
  gap. ⭐ **Recommend (b) + (c):** the child is created *by* the parent, so the
  parent's relevant context is available at exactly the moment the child is
  homed, and copying it then costs one write instead of a cross-region read on
  every hop. (c) is the fallback for genuine ancestry queries. Reject (a) — it
  puts a cross-region round trip on a hot path to buy freshness the model does
  not require. ⚠ (b) is a denormalisation, so it inherits F4's hazard: copy only
  what is **immutable** about the parent (ids, playbook identity), never its
  mutable status.
- **F8 — what happens to executions orphaned in a lost region?** Raised by §7.1
  and currently **undecided**. Options: retry as a new `execution_id` homed
  elsewhere; leave them pending the region's return; or an operator-driven
  re-home. ⭐ **Recommend "retry as new, with the original recorded as the
  retry's parent execution"** — it needs no cross-region write path, and the tree
  edge (I3) already expresses the lineage. ⚠ Do not let this stay undecided
  while calling M8 unnecessary: the de-scope in §7.1 is only honest if this
  question has an answer.
- **F9 — is `exec_seq` or the HLC the cross-region merge order for *reads that
  span executions*?** ⭐ **The HLC (M2).** `exec_seq` is intra-execution by
  construction and means nothing across partitions; `global_sequence` is
  per-engine and means nothing across regions. Anything presenting a merged
  cross-execution view (a UI timeline, an audit export) orders by HLC and must
  label the result **bounded-stale**, never "complete".

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
4. **The consistency budget splits on the partition boundary** (§2.4, owner
   constraint): **strong ordering only within an `execution_id` partition**,
   **eventual across replicas and regions**. Executions are **homed**;
   "geographically distributed" means many single-writer partitions in many
   regions, never one chain written from two.
5. **Eventual is provably safe here** (§2.5). *Property N — non-divergence*: a
   single writer gives each event at most one successor and immutability fixes
   its parent pointer, so **no replica can ever observe a forked chain** — it
   sees a subset, never a contradiction. ⚠ N depends on real single-writer
   exclusion, so **the eventual model's safety is conditional on M5 fencing**.
   The weaker *Property P — prefix* (no holes) needs per-partition **ordered**
   replication and is a usability, not a safety, requirement.
   ⭐ And the chain is **self-verifying**: the `prev` pointer *names the missing
   key*, so staleness becomes a reportable gap instead of an empty result — the
   same invariant that kills the re-drive.
6. **Durable Objects is the right reference model and not a candidate**
   (edge-only) — and under §2.4 the fit is exact: strong *within* an object,
   nothing across. **JetStream is rejected as the store** (per-execution
   subjects are the documented cardinality antipattern; it reverses the T5 NATS
   deletion) but its **source/mirror streams are prior art for the replication
   half** — which NoETL already implements as the async mirror.
   **Cockroach KV is rejected, and §2.4 strengthens the rejection**: its global
   strong consistency is now an **over-buy paid as consensus on every append**,
   a latency tax for a property §2.5 shows the chain does not use.
7. **Recommend the native restructure**: tier on L0 (R1), sort key
   `(execution_id, exec_seq)` (R2), a point index for the parent (R3),
   chain-*following* instead of chain-*reconstruction* (R4), **execution homing**
   (R5) and a **per-partition ordered async mirror** (R6).
8. It **shares its first phase with the multi-region plan** (M0.5 = R1) and its
   partition function with M1/M4. One repartition serves placement and retrieval.
9. ⭐⭐ **§2.4 largely dissolves the plan's hardest fork.** Because executions are
   homed, losing a region does not strand a chain that must be written: new work
   is homed elsewhere immediately and everything replicated stays readable. **M8
   (region-survivable writes) drops from "needed" to "optional"**, and F2b stops
   being a blocker — at the price of one new question, F8, about executions
   orphaned mid-flight.
10. The migration ends by **deleting** the cap, the budget, the tombstones and the
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

---

## 11. MVP slice — converged recommendation and first increment

**Added 2026-09-24 on the owner's instruction to converge fast and start
building in the same session.**

### 11.1 The recommendation, in one paragraph

**Build the native EHDB restructure.** It is the fastest path to a working
slice because the substrate already exists and is already partitioned the right
way: `ehdb-l0` has immutable parts, a manifest, a sparse index, `partition =
shard_for(execution_id)` and a per-part bloom over `execution_id` — what it
lacks is a per-execution sort key and a point index, which are additive. The
alternative that could in principle be faster — a JetStream stream or subject
per `execution_id` — is **not** faster to a *working* slice: it needs a NATS
deployment this platform deliberately deleted at T5, it lands on the documented
high-cardinality-subject antipattern the moment `execution_id` counts grow, and
its per-execution ordering would still have to be bridged into the existing
drive. Everything else is in the matrix (§5) and is not revisited: Durable
Objects is the right shape and edge-only, Cockroach over-buys consistency §2.4
says we do not want, CF KV/D1/R2 are edge roles.

### 11.2 The MVP slice

Smallest thing that delivers the four required behaviours, behind a flag,
default off, additive, existing behaviour unchanged when off:

| # | behaviour | slice surface |
| :-- | :-- | :-- |
| **a** | append an event to an `execution_id` partition | `ChainStore::append` — per-execution `exec_seq`, refuses an append that does not extend the head (I1) |
| **b** | O(1) fetch of the predecessor | `ChainStore::parent_of` — one index probe via `(execution_id, event_id) → exec_seq` |
| **c** | ordered read of an execution's chain | `ChainStore::chain` / `walk_from_head` — contiguous over one partition |
| **d** | advance by chain-**following**, not reconcile/re-drive | `chain_is_complete` — complete, or **incomplete at a named key**, never an empty result |

Flag: `NOETL_EHDB_EXEC_CHAIN`, default **off**, unrecognised ⇒ off.

**Increment 1 (landed):** the primitive plus its proofs, `ehdb-l0/src/chain.rs`,
**INERT** — not wired to the tier, engine, drive or any write path.

**Increment 2 (next):** persist a partition to the L0 substrate and re-prove
P1/P2 against a durable store with a `CountingSubstrate`, so pattern A is shown
to issue exactly one storage operation rather than one map probe.

**Increment 3:** a read-only shadow comparison — for a real execution, compare
the chain-followed spine against the current scan-built spine, count agreement,
serve neither.

**Increment 4:** the flag's first real consumer — the drive consults
`chain_is_complete` and distinguishes *incomplete at key K* from *not ready*,
which is what makes E5/E6 (retire the re-drive and its cap) possible.

### 11.3 What increment 1 proved, and the design gap it found

- **P1** — parent lookup flat across a **100×** growth in `N` (100 → 10,000
  events), ratio asserted `< 5×`.
- **P2** — chain read flat across the same 100×, with `k` fixed at 10.
- ⭐ **A positive control** that deliberately scans every partition and asserts
  the ratio **> 10×**. Without it, the two flat readings prove only that the
  harness cannot measure, which is the same reading as success.
- **Gap naming** — a missing link reports `GapAt { execution_id, event_id }`.
- Mutation battery **8 planted / 8 caught**, positive control green.

⚠⚠ **The battery found a real design gap, not just a missing test.** The mutant
*"`chain_is_complete` reports true on a gap"* **survived**, because a gap was
**unconstructible**: `append` enforces the head, so no test could build a
partition with a hole for the assertion to bite on. But §2.5 Property P says
async replication **may deliver out of order** — so a follower must be able to
hold `e₃` while waiting for `e₂`, and that path did not exist in the slice.

Increment 1 therefore also adds **`apply_replicated`**, the follower ingest
path, and the asymmetry is now explicit and deliberate:

| path | enforces the head? | why |
| :-- | :-- | :-- |
| `append` — **writer** | **yes** | I1. The home partition's chain cannot fork |
| `apply_replicated` — **replica** | **no** | Out-of-order delivery is normal. Property N still holds, so what arrives is a *subset of one fixed path*: a hole is a **gap**, never a **fork** |

And `chain_is_complete` now compares the walk against the partition's **span**
(highest `exec_seq`), not against how many records happen to be present — a
count comparison is satisfied by *"I hold 2 of 3 and walked 2"*, which is
precisely the false-complete the design exists to prevent. A **contiguous
prefix** is reported complete (behind is not broken); a **hole** is not.

`ChainError::Forked` is retained as the **Property N alarm**: single-writer
exclusion should make it unreachable, so if it ever fires in the field,
exclusion was not real. It is the detector, not the guard.

---

## 12. Pluggable storage roles — EHDB as the default, not a dependency

**Owner requirement, 2026-09-24, first-class:** all storage integration is
**abstract/pluggable**, so an operator configures **at runtime** which backend
each noetl internal workload uses, **per storage role**. EHDB becomes the
default implementation, not a hard dependency.

### 12.1 The precedent, verified and mirrored

`noetl/ops#311` (**OPEN**, VERIFIED via `gh`) does this for models:

```
NOETL_SLM_BACKEND = ollama | vertex | vertex-stub | vllm     # default: ollama
```

with two properties worth copying exactly:

- **Precedence: explicit call-site argument → flag → default.**
- *"A call site that passes nothing and runs with no flag behaves exactly as it
  does today."*

⭐ And a third, easy to overlook: it ships a **`vertex-stub`**. A stub backend is
not clutter — it is how you demonstrate that the selection machinery and the
acceptance criteria actually *reject* something. §12.4 carries it over.

⚠ ops#311 is Python, in `automation/agents/mcp/model_backend.py`. Storage roles
are Rust. The **shape** is mirrored; no code is shared.

### 12.2 The roles

| role | env var | contract | default |
| :-- | :-- | :-- | :-- |
| **EventLog** | `NOETL_STORE_EVENTLOG` | **`EventStore`** — the 4-id chain model (§2), in full | `ehdb` |
| **Projection** | `NOETL_STORE_PROJECTION` | serving/projection tier | `ehdb` |
| **Context** | `NOETL_STORE_CONTEXT` | internal execution-context management | `ehdb` |
| **KV** | `NOETL_STORE_KV` | existing KV role | `ehdb` |
| **Object** | `NOETL_STORE_OBJECT` | existing object role | `ehdb` |
| **Vector** | `NOETL_STORE_VECTOR` | existing vector role | `ehdb` |

Roles resolve **independently** — setting `NOETL_STORE_CONTEXT=redis` must not
move Projection. Every role defaults to `ehdb`, and an **unrecognised value
resolves to `ehdb`**, so a typo can never silently relocate a workload.

### 12.3 ⚠ Where the seam is — the thin-hot-path requirement, as a design rule

The requirement is that the O(1) predecessor fetch and the per-execution append
are not slowed by indirection. That is satisfied by **granularity**, not by
micro-optimising:

> **The seam is at the workload boundary, not inside the chain walk.**

`EventStore` is deliberately **coarse-grained**: one call per *logical
operation*. `walk_from_head` returns the whole chain, so a 200-event walk
crosses the seam **once** and the inner loop stays inside the implementation,
monomorphised and borrow-based. A fine-grained trait — `next_event()` per step —
would put a virtual call **and** an allocation in the inner loop. That is the
shape this rule forbids, and there is a test asserting the ratio so the
regression is caught rather than argued about.

⚠ Trait methods return **owned** values, because a remote backend has no borrow
to hand back. That is a real cost (one clone per returned event) and it is
bounded and measured; in-process callers wanting borrows keep using the concrete
`ChainStore`. **The trait is the configuration seam, not the inner-loop seam.**

### 12.4 Conformance — a backend is usable only if it passes

`EventStore` conformance checks the §2 contract clause by clause, each named so
an operator sees *which* guarantee a candidate lacks:

```
append/per-execution-seq-starts-at-1     chain/partition-isolation
append/accepts-root                      chain/ascending
append/enforces-head (I1)                parent_of/resolves-predecessor
parent_of/names-the-gap                  apply_replicated/accepts-out-of-order
apply_replicated/idempotent              chain_is_complete/hole-is-incomplete
get/by-key                               chain_is_complete/prefix-is-complete
```

Two clauses carry most of the weight, and they are the two the RFC exists for:
**`parent_of/names-the-gap`** (a missing predecessor must name its key, never
return `None`) and **`chain_is_complete/hole-is-incomplete`** (a hole must not
read as finished). The paired control **`prefix-is-complete`** stops a backend
satisfying those by calling everything incomplete — *behind is not broken*.

⭐⭐ **A conformance suite is only worth having if it rejects something**, so two
non-conforming backends ship with it:

| backend | verdict | why it is informative |
| :-- | :-- | :-- |
| `stub` | **REJECTED** | Accepts everything, remembers nothing, reports every chain complete. The suite's own positive control, mirroring ops#311's `vertex-stub` |
| `jetstream-sketch` | **REJECTED**, on the clauses that matter | Passes `chain/ascending` and `chain/partition-isolation` — a subject per execution genuinely gives ordered replay and isolation. **Fails** `parent_of/names-the-gap` (a replay cannot distinguish "not yet" from "not a thing"), `chain_is_complete/hole-is-incomplete` ("everything in the subject" always looks complete) and `append/enforces-head` (nothing in a plain publish refuses a stale-head append; `expected_last_subject_sequence` is the concrete thing a real implementation would have to add) |

⭐ The sketch passing *some* clauses is the point. A suite that rejected it
wholesale would be indistinguishable from one that rejects everything; a suite
that accepted it would not be checking the two properties the redesign is for.
**That split verdict is the evidence the contract is a specification rather than
a restatement of EHDB's method signatures.**

### 12.5 How this changes the recommendation and the migration

The recommendation (§11.1) is unchanged in substance and sharper in framing:
**EHDB is the default implementation of the EventStore contract**, and the
contract — not EHDB — is what the rest of noetl depends on. Anything satisfying
§2 can serve the role.

Migration additions, slotting into §8:

| phase | what | flag | exit criterion |
| :-- | :-- | :-- | :-- |
| **E1a** | Storage-role registry + per-role config; **every role defaults to `ehdb`** | `NOETL_STORE_*` | unset/typo ⇒ `ehdb`; roles independent; a `*_info` gauge reports **every** role's resolved backend including defaulted ones (an absent label reads identically to a broken exporter) |
| **E1b** | `EventStore` trait + EHDB impl + conformance suite | — | EHDB passes; **`stub` and `jetstream-sketch` are REJECTED on named clauses**; the seam's hot-path ratio is asserted |
| **E3a** | Extract `ProjectionStore` and `ContextStore` behind the same pattern | `NOETL_STORE_PROJECTION`, `NOETL_STORE_CONTEXT` | today's behaviour byte-identical under the defaults |

⚠ **E1a and E1b are additive and inert.** Adding a seam whose only
implementation is the incumbent changes nothing at runtime — which is exactly
the property that makes it safe to land early and ahead of the restructure.
