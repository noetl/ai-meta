# ehdb#322 — group-commit and quorum-ack: what the code actually supports

**Design only. Nothing built, nothing deployed, no prod change.**
Written 2026-09-03 against `noetl/ehdb@0980183` and the live
`shastaratech-noetl-prod` cluster.

Every claim below is against the real types and the real cluster. Where I
measured, the method is stated. Where I estimated, it says so.

---

## The finding that reframes all four questions

**Group-commit is not a proposal. It shipped, and it is running in production
right now.**

`FeedWriter::new` (`crates/ehdb-feed/src/lib.rs:315`) unconditionally does:

```rust
engine.set_flush_policy(FlushPolicy::CallerDriven);
```

`FlushPolicy::CallerDriven` (`crates/ehdb-l0/src/part.rs:54`) is group-commit,
landed for noetl/ai-meta#205. And `serve_ingest`'s committer
(`crates/ehdb-feed/src/publish.rs:146-160`) already coalesces:

```rust
// Take only what is already queued — never wait to batch.
while batch.len() < MAX_COMMIT_BATCH { ... }
let seqs = writer.append_batch(std::mem::take(&mut batch));
```

`MAX_COMMIT_BATCH = 512` (`publish.rs:46`). One lock, one `fsync`, N acks.

**So the ~4 ms measured in noetl/ai-meta#319 is already the group-committed
number, at batch size 1.** It is not a missing optimisation. It is
group-commit with nothing to coalesce.

That single fact answers the c=1 question before we get to it, and it changes
what "add group-commit" can possibly mean.

---

## Q1 — Can group-commit and quorum-ack both exist, selectable via config?

**Yes, and they are naturally orthogonal axes, not alternatives.**

They answer different questions:

| axis | question | where it lives today |
| :-- | :-- | :-- |
| `FlushPolicy` | **when** does the local `fsync` happen? | per-`PartWriter`, `part.rs:35`; set via `L0Engine::set_flush_policy` (`engine.rs:583`), which loops every writer (`engine.rs:586`) |
| *(does not exist)* | **who else** must confirm before we ack? | — |

`FlushPolicy` already has three variants, and the third is group-commit:

- `EveryAppend` — `fsync` per append. The D1 default for a bare engine caller.
- `Buffered { fsync_every: u32 }` — `fsync` every N records. Documented
  "derived/metrics tiers only".
- `CallerDriven` — never `fsync`s on its own; the caller closes the window over
  a whole batch. **This is group-commit, and it is what the writer runs.**

So group-commit is *already* a config axis in the type system. What it is not
is *configurable* — `FeedWriter::new` hard-codes it.

### The concrete shape

Add a second, orthogonal enum, resolved once per writer:

```rust
pub enum DurabilityMode {
    /// Today's posture. Local fsync over the batch; ack immediately after.
    LocalGroupCommit,
    /// Local fsync, then await `n` confirmations before acking.
    GroupQuorum { n: u8 },
    /// Await `n` confirmations with no local batching (degenerate; listed so
    /// the config can express it, not because it is a good idea).
    Quorum { n: u8 },
}
```

**Where it wires in — one seam, and it already exists.** `ehdb-feed`'s

```rust
fn commit(handles: &[std::fs::File]) -> io::Result<()> {
    for handle in handles { handle.sync_data()?; }
    Ok(())
}
```

is called by exactly two callers — `append` and `append_batch` — and both write
their acks *after* it returns. That is the single place the durable-ack
contract is closed, so it is the only place a quorum wait has to go. No other
code needs to know.

**Per-subject selection is natural; per-record is not.** The writer process
hosts more than one engine (`/data/cmdbus` on :9102, `/data/eventbus` on :9106,
`/data/eventkv`), each its own PVC and its own `FeedWriter`. Mode belongs at
that construction site — one mode per dataset. It cannot be per-record: a batch
has **one** commit point, so a mixed-mode batch has no coherent ack rule.

⚠ Being selectable is not the same as being safe to select. See Prerequisites.

---

## Q2 — Can they be combined?

**Yes, and the combined shape is the only one worth building.**

Target: **one `fsync` + one replication round-trip per batch.**

The code is already the right shape for it. `append_batch`
(`ehdb-feed/src/lib.rs:421`):

1. take the engine lock
2. append N records (`append_writer_assigned` each)
3. `take_sync_handles()`, release the lock
4. `commit(&handles)` — **one `sync_data()` for the batch**
5. send the tip, return N sort keys; `serve_ingest` writes N acks in request
   order

The quorum wait slots in **between 4 and 5**: after the local fsync proves the
batch durable here, ship the batch's tip sequence to replicas and await `n`
confirmations, then release the acks. Cost per batch becomes `fsync + RTT`
rather than `N × (fsync + RTT)`.

This is not a redesign. `publish.rs:79` already describes the batch as "one
engine lock, one `fsync`, one follower wake for the whole batch" — the batch is
already the unit of the ack contract. Quorum inherits that unit for free.

⚠ **"Follower" in that comment is a feed *reader*, not a replication
participant.** No confirmation path exists. See Prerequisites.

---

## Q3 — Does quorum-ack give microsecond latency?

**No. Measured on this cluster, a round-trip is ~1.2 ms — three orders of
magnitude above µs, the same order as the `fsync` it is being added to.**

ICMP from the `noetl-server-rust` pod (10.119.0.28, node `…-w5zt`) to the
`noetl-cmdbus-writer` pod (10.119.0.223, node `…-5pb5`) — **different nodes**,
30 packets, two runs:

```
round-trip min/avg/max = 1.117/1.320/2.461 ms
round-trip min/avg/max = 1.004/1.180/2.035 ms
```

Loopback in the same pod, to separate stack cost from network:

```
round-trip min/avg/max = 0.046/0.066/0.084 ms      -> 66 µs
```

So: **~66 µs of it is the local network stack; ~1.1 ms is the hop between
Autopilot nodes.** A same-node replica would cost ~66 µs per round-trip; a
cross-node one ~1.2 ms. Neither is µs in the single-digit sense, and the
cross-node figure is the honest planning number because pod placement is not
pinned.

Caveats, stated rather than buried: ICMP is a floor — it excludes TLS,
framing, serialisation and the follower's own `fsync`. A real quorum
confirmation that requires the follower to be *durable* costs its `fsync` too,
which on the same hardware is another ~4 ms and would dominate everything here.
A quorum that only requires the follower to have *received* the bytes is the
~1.2 ms case.

**Plainly: per-operation quorum is a round-trip. It is µs only when amortised
over a batch.**

### ⚠ And #322's own premise needs correcting

The issue says an append should be acknowledged "after N (configurable quorum)
**durable-substrate** replicas confirm". Against the code:

- The only `DurableSubstrate` implementations are `LocalFsSubstrate`
  (`substrate.rs:106`), `InMemorySubstrate` (`substrate.rs:498`) and the
  `CountingSubstrate` wrapper. **There is no object-store substrate.**
- The writer's mounts are three PVCs — `cmdbus-data`, `eventbus-data`,
  `eventkv` — and each engine's substrate `parts` directory lives on **its own
  same PVC** (`/data/cmdbus/parts`, `/data/eventbus/parts`,
  `/data/eventkv/parts`). No bucket is configured anywhere on the StatefulSet.

So the async replication whose window `unreplicated.rs` measures currently ends
**on the same disk it started on**. The D1 window is real and correctly
measured, but the thing at the far end of it adds **no failure-domain
separation at all** today. That is ehdb#332's subject, and it is a hard
prerequisite rather than a nicety.

If a future substrate is object storage, its round-trip is tens of ms, not
1.2 ms, and synchronous quorum against it is off the table for the request
path at any batch size worth having.

---

## Q4 — At what batch size does (fsync + RTT)/N cross into µs?

Using the measured numbers: **`fsync` = 4.0 ms** (noetl/ai-meta#319's
`dispatch_bench` C hop, p50 3,978–4,071 µs, stable across every shape) and
**RTT = 1.2 ms** cross-node / **0.066 ms** same-node.

Per-record cost in **µs**:

| N | group-commit only | GC + quorum (cross-node) | GC + quorum (same-node) |
| --: | --: | --: | --: |
| 1 | 4000.0 | 5200.0 | 4066.0 |
| 2 | 2000.0 | 2600.0 | 2033.0 |
| 4 | 1000.0 | 1300.0 | 1016.5 |
| 8 | 500.0 | 650.0 | 508.2 |
| 16 | 250.0 | 325.0 | 254.1 |
| 32 | 125.0 | 162.5 | 127.1 |
| 64 | 62.5 | 81.2 | 63.5 |
| 128 | 31.2 | 40.6 | 31.8 |
| 256 | 15.6 | 20.3 | 15.9 |
| **512** *(MAX_COMMIT_BATCH)* | **7.8** | **10.2** | **7.9** |
| 1024 | 3.9 | 5.1 | 4.0 |
| 5200 | 0.8 | 1.0 | 0.8 |

Thresholds for GC + cross-node quorum:

| target | required N |
| :-- | --: |
| < 1000 µs (sub-millisecond) | **6** |
| < 100 µs | **52** |
| < 10 µs | **520** |
| < 1 µs | **5200** |

**Three things fall out of this table.**

1. **Sub-millisecond is cheap.** N ≥ 6 gets there. Under any real concurrency
   the batcher reaches that easily.
2. **~10 µs/record is the floor at today's cap.** `MAX_COMMIT_BATCH = 512` puts
   the best achievable at **10.2 µs** with quorum, **7.8 µs** without. Single-
   digit µs needs N ≥ 520 — i.e. **raising the cap is a prerequisite for
   single-digit µs, and it is a one-constant change independent of quorum.**
3. **Sub-µs is unreachable.** It needs N ≥ 5,200, an order of magnitude past the
   cap, and the batch would then span seconds of arrivals.

Note the third column: with a **same-node** replica, quorum is nearly free —
the curve is within 2% of group-commit alone, because 66 µs disappears next to
a 4 ms `fsync`. **The `fsync` dominates quorum, not the other way round.** If a
replica can be placed on the same node, quorum-ack costs almost nothing; if it
cannot, it costs ~30% on top of `fsync`.

---

## What group-commit gives NOW — quantified

The committer **never waits** (`publish.rs:152`, and the doc comment at
`publish.rs:80-83` says so explicitly: "a lone record still commits
immediately"). Batch size therefore equals *whatever happened to be queued*.

| situation | batch | per-record cost |
| :-- | --: | --: |
| **c=1**, one record in flight | **1** | **4000 µs** — unchanged from no group-commit |
| light concurrency, ~8 queued | 8 | 500 µs |
| heavy, cap reached | 512 | 7.8 µs |

**At c=1 group-commit does exactly nothing, by design.** It cannot: there is
nothing to coalesce, and waiting for something to coalesce with would *add*
latency to the very request being measured. The 4 ms at c=1 in
noetl/ai-meta#319 is not a bug and not an un-applied optimisation — it is the
floor of the current durability contract.

⚠ **And we cannot currently see any of this on prod.** `batch_len` exists at
`publish.rs:159` but is used **only in a log line**. There is no metric — I
checked `L0Metrics` and scraped the live writer's `:9102/metrics`, and nothing
carries commit batch size. **The single number that says whether group-commit
is doing anything is invisible in production.** Every row of the table above is
therefore a model, not an observation.

---

## The c=1 sub-choice, precisely

Getting µs at concurrency 1 means the ack must stop waiting for the `fsync`.
There are exactly three levers and only one of them is a design choice:

1. **Wait to batch** (timed group-commit, Nagle-style). At c=1 there is nothing
   to wait *for*, so this strictly **adds** latency. It converts an
   opportunistic batcher into a timed one, which helps throughput under load
   and hurts the c=1 case. **Not a c=1 answer.**
2. **Faster `fsync`.** A different disk class changes the 4 ms constant. This
   is a procurement decision, not a design one, and it moves the whole curve
   without changing its shape.
3. **Ack before `fsync`.** The only route to µs at c=1. It is a **durability
   trade**, and the machinery already exists: `FlushPolicy::Buffered {
   fsync_every }` (`part.rs:42`), today documented "Faster, larger crash window;
   derived/metrics tiers only."

### What accepting the crash window actually means here

For the command bus specifically: an acked `command.issued` that has not been
`fsync`'d is a command the **server believes is durable** and which a node loss
erases. Downstream, the server has already returned success on
`POST /api/execute`. So the failure mode is *an execution the caller was told
started, which then never happened, with no record that it was lost* — the
worst shape of failure this platform has, and the one noetl/ai-meta#208's 10 s
publish deadline exists to prevent at a different layer.

The window's size is `fsync_every` records **plus** the time to accumulate
them — on a quiet shard the second term dominates and is unbounded by
`fsync_every` alone. Bounding it needs an age trigger; `NOETL_EHDB_SEAL_MAX_AGE_MS`
= 5000 exists on the writer for sealing, and an equivalent flush-age bound
would be needed here.

**Recommendation: do not take this for the event log or the command bus.** If
µs at c=1 is genuinely required for some path, take it per-dataset for a
derived tier where a lost suffix is recomputable — which is exactly what
`Buffered`'s doc comment already says.

---

## Prerequisites — what must be true before quorum is deployable

Group-commit needs **none** of this, which is why it already ships.

Quorum-ack needs all of it:

| # | prerequisite | status today | evidence |
| :-- | :-- | :-- | :-- |
| 1 | A **second replica** with an independent failure domain | **absent** — single writer, and each engine's substrate is a directory on *its own same PVC* | mounts `cmdbus-data` / `eventbus-data` / `eventkv`; `/data/*/parts` |
| 2 | A **synchronous confirmation protocol** | **does not exist** — "follower" in `publish.rs` is a feed *reader*; replication is async upload on seal | `unreplicated.rs` header |
| 3 | **Writer election** (C5) | code exists, **inert** — issues tokens without being authoritative | `ehdb-reference/src/election.rs` |
| 4 | **Fencing** enforcement | code exists, **inert** — counts and refuses nothing | `ehdb-reference/src/fencing.rs` |
| 5 | A substrate that is not the same disk | **ehdb#332** | only `LocalFsSubstrate` / `InMemorySubstrate` exist |

Two of these are hard blockers rather than work items: without (1) there is
nothing to ack against, and without (3)+(4) a two-writer configuration is a
split-brain risk that is *worse* than the RF=1 window #322 is trying to close.
**Enforce-before-election is an outage, not a degradation** — sequencing is
already recorded in `playbooks/324-four-gates/`.

---

## Recommended phasing

### Phase 0 — already done, and worth recognising as done

Group-commit is live (`CallerDriven` + the opportunistic committer). No work.

### Phase 1 — buildable and deployable NOW, needs no replica

**1a. Make the batch size observable.** A histogram of commit batch size on the
writer. This is the highest-value item on the whole list and the smallest:
without it, nobody can say whether group-commit is helping, and every number in
the curve above stays a model. It also directly answers "is the system ever
reaching N ≥ 6" — which is the difference between sub-ms and 4 ms.

**1b. The config scaffold, fail-closed.** Introduce `DurabilityMode`, thread it
to the `commit()` seam, implement only `LocalGroupCommit`. The `Quorum` and
`GroupQuorum` variants **parse and then refuse to start** with a message naming
the missing prerequisite. A mode that silently degrades to local-only would be
the worst possible outcome — it would report quorum durability while providing
none, which is this repo's recurring failure shape.

**1c. Consider raising `MAX_COMMIT_BATCH`.** 512 → 1024 halves the amortised
floor (7.8 → 3.9 µs/record) for a one-constant change. Needs measuring against
part-size and ack-latency effects first — a bigger batch means the *first*
record in it waits longer.

All three are inert with respect to durability: none changes when a record
becomes durable.

### Phase 2 — gated on ehdb#332 + C5 + fencing

The follower confirmation protocol and `GroupQuorum { n }`. Do not start this
before (1), (3) and (4) above are real, and do not deploy it before the batch
metric from 1a exists — otherwise the first question after enabling it ("is
this costing us a round-trip per record or per batch?") is unanswerable.

### Phase 3 — separate decision, not required by the above

`ack-before-fsync` for any path that genuinely needs µs at c=1, per-dataset,
derived tiers only, with an age-bounded flush. **Recommend not taking it for
the event log or command bus.**

---

## Direct answers

1. **Both, config-selectable?** Yes. They are orthogonal axes: `FlushPolicy`
   (when the local `fsync` happens — group-commit already lives here and is
   already on) and a new `DurabilityMode` (who else must confirm). One seam,
   `ehdb-feed`'s `commit()`. Per-dataset, not per-record.
2. **Combined?** Yes, and it is the only version worth building: one `fsync`
   plus one round-trip per **batch**, with the wait inserted between
   `commit()` and the acks. The batch is already the ack unit.
3. **Does quorum give µs?** No. **1.2 ms** cross-node measured on this cluster,
   66 µs same-node. Per-operation quorum is a round-trip. It is µs only
   amortised — and `fsync` dominates it either way.
4. **Where does it cross into µs?** N ≥ 6 for sub-ms, N ≥ 52 for < 100 µs,
   **N ≥ 520 for < 10 µs** — just past the current `MAX_COMMIT_BATCH` of 512,
   which pins the floor at **10.2 µs/record**. Sub-µs (N ≥ 5,200) is
   unreachable.

And the one that was not asked: **at c=1 none of this helps, because
group-commit is already running and has nothing to batch.** µs at c=1 requires
accepting a crash window, and for the command bus that means telling a caller
their execution started and then losing it.

---

# Addendum — the delivery hop, and why it outranks the durability question

Added 2026-09-03 after tracing noetl/ai-meta#320 into this design. Read-only;
no load was generated.

## The chain, traced

The records whose durability #322 is about do not arrive at the writer
directly. They travel:

```
noetl-server-rust
  --POST /ehdb/tiers/eventlog-->  noetl-worker-system-pool  (:9090, ONE pod)
     --tier service-->            noetl-cmdbus-writer-0     (:9110)
        --L0 append + fsync-->    /data/eventbus
```

Confirmed from the live cluster:

- server: `NOETL_EHDB_WORKER_QUERY_URL = http://noetl-worker-system-pool-metrics…:9090`
- worker system pool: `NOETL_EHDB_TIER_QUERY_SOURCE = service`,
  `NOETL_EHDB_TIER_SERVICE_ADDR = noetl-cmdbus-writer-0…:9110`
- writer: `NOETL_EHDB_TIER_SERVICE_BIND = 0.0.0.0:9110`,
  `NOETL_EHDB_TIER_SERVICE_DIR = /data/eventbus/ehdb-tier`
- the append route is `POST /ehdb/tiers/{tier}` in the worker's
  `metrics_server.rs:621`, whose own doc says the write must resolve its store
  the same way the read does, "or the comparator would report an artefact of
  two different stores rather than a fact about either"

**So the mirror relay is inside the durability chain, not beside it.** Every
guarantee the writer's `fsync` provides is downstream of two network hops that
provide none.

## ⚠ And the tier is already `primary`

The worker system pool carries `NOETL_EHDB_EVENTLOG = primary`, and its
`/metrics` reports

```
noetl_ehdb_eventlog_ops_total{operation="mirror",outcome="served_primary"} 21912
```

⚠ I checked the **server** for a `served_primary` series earlier and found
none, and concluded the tier was not serving. That was the wrong place to look
— the serve decision lives on the **worker**. Correcting it here rather than
leaving the earlier reading standing. (What these counters establish is that
the eventlog tier is in `primary` mode and the mirror op takes the primary
path 21,912 times; I did not establish from them whether user-facing *reads*
resolve from the tier.)

#322 says to "**gate** the Phase 9 tier-1 (event log) primary cutover on the
window being bounded and monitored". The mode is already `primary` while the
window is neither bounded (the substrate is a directory on the same PVC) nor
fed by a lossless path. The gate is behind the thing it was meant to gate.

## What #320 proves about fan-out — and it is not an assumption any more

noetl/ai-meta#320, measured on this cluster this session:

| | serial drain (v3.100.3) | concurrency 8 (v3.100.4) |
| :-- | --: | --: |
| `mirrored` | 3541 | 101 |
| `unavailable` + `degraded` | 154 | 11,969 |
| failure rate | **4.2%** | **99.2%** |

The relay endpoint is a **headless service with exactly one endpoint pod**. It
answers a single probe instantly and collapses at eight concurrent POSTs.

**A batched or quorum design cannot assume replication endpoints scale with
fan-out, because in this system the one endpoint we have does not.** That is
now an observation, not a risk.

Three consequences for the design above:

1. **Quorum fan-out must be sized against a measured endpoint, not a
   configured replica count.** `GroupQuorum { n }` implies `n` concurrent
   confirmations in flight. On this cluster, `n = 8` against a single-pod
   endpoint produced a 99% failure rate. Whatever `n` becomes, its per-endpoint
   concurrency needs a measured ceiling and a bounded queue in front of it —
   the same shape the mirror queue has, and the same shape that failed.
2. **The batch helps here too, and for a second reason.** Everything in Q4 is
   about amortising `fsync + RTT` over N. The relay adds a third term:
   *requests per second at the endpoint*. Larger batches reduce the request
   **rate** for the same record rate, which is precisely the pressure that
   broke the relay. Batching is therefore not only a latency lever but the
   main lever for staying inside this endpoint's capacity — an argument for
   raising `MAX_COMMIT_BATCH` that is independent of the µs curve.
3. **Ordering and retry become load-bearing at the same moment.** The relay
   drops a failed batch — `deliver`'s `Err` arm logs and returns
   (`ehdb_eventlog_mirror.rs:388`). A durability design whose delivery path can
   silently discard records is not a durability design.

## The conclusion this forces

**Bounding the D1 window is the second problem, not the first.**

D1 asks: *once a record reaches the writer, how long until it is safe?*
Today's answer is bad — the substrate is the same disk — and #322 is right to
attack it.

But the prior question is: *does the record reach the writer at all?* Today's
answer is **not reliably**, and when it doesn't, nothing anywhere records
which record was lost. During the #320 window roughly **12,000 batch
deliveries** were dropped with no retry and no dead-letter, into a tier whose
mode is `primary`.

A synchronous quorum-ack would make the last hop of that chain very safe while
the first hop stays lossy. That is spending the expensive fix on the wrong
segment.

**Sequencing that follows:** make delivery lossless and observable *before*
building quorum. Concretely, ahead of Phase 2:

- **retry or dead-letter a failed mirror batch** — the current `Err` arm is the
  single highest-severity line in the chain;
- **a success-rate metric read beside `emit_mirror`** — a 99% failure rate
  presented as a latency improvement is exactly what happened, because latency
  was instrumented and outcome was not;
- **a measured concurrency ceiling for the relay endpoint**, which requires a
  load run and is therefore held.

None of this is a durability trade. All of it is a prerequisite for one being
meaningful.

## Revised phasing

| phase | work | gated on |
| :-- | :-- | :-- |
| **0** | group-commit — **already live** (`CallerDriven` + opportunistic committer) | — |
| **0.5** *(new)* | delivery is lossless + observable: mirror retry/dead-letter, success-rate metric, measured relay ceiling | a load run (held) |
| **1** | commit-batch-size metric; `DurabilityMode` scaffold, fail-closed; consider `MAX_COMMIT_BATCH` 512→1024 | nothing — buildable now |
| **2** | follower-ack protocol, `GroupQuorum { n }` with a per-endpoint concurrency bound | ehdb#332 replica, C5 election, fencing enforcement, **and 0.5** |
| **3** | ack-before-fsync, per-dataset, derived tiers only | a separate durability decision; **not** recommended for the event log or command bus |

Phase 0.5 is new, and it is ahead of Phase 2 on purpose.
