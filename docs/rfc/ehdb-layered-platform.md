# RFC: EHDB as a Layered Platform (L0→L3) — L0-First

**Status:** RFC — design + build plan. DESIGN ONLY, no build.
**Supersedes the top-level framing of:**
[`ehdb-nats-takeover-plan.md`](./ehdb-nats-takeover-plan.md) — the flat
"NATS takeover" is now **one layer (L1)** of this platform, sitting on L0.
That document is retained as the **L1 (streaming) design detail**; its
storage/durability/HA are now inherited from L0 (see §2.5 — the per-shard-Raft
"T-RF" HA plan is **superseded** by L0 object-store replication).
**Date:** 2026-07-15.
**Program tracker:** noetl/ai-meta#194.
**Decisions (locked 2026-07-15):** **(1)** EHDB is a **layered platform**,
**built L0-first**: L0 replicated object store → L1 streaming → L2 KV → L3
append-log SQL. **(2)** L0's write+index engine is **modeled on
VictoriaMetrics / VictoriaLogs** (buffered flush → immutable parts →
background merge → inverted-index-first → columnar), with the **honest
departure in §2.2**.
**Issues:** ehdb#241, ehdb#254 (durable segments — L0 seed), ehdb#234,
ai-meta#178, ai-meta#166, ai-meta#116, ai-meta#130, ai-meta#267 (O(1) open),
Phase-8 object/KV/vector tiers, ai-meta#104 (Arrow Feather result tier).

---

## 0. The reframe

Earlier drafts treated "remove NATS" as the whole program and kept hitting the
same wall: **durability, replication, and HA**. The (c) topology ended with a
deferred, quarters-long **per-shard Raft** ("T-RF") to give the writer HA — a
consensus build bolted onto a delivery layer. That is the wrong place to solve
durability. This RFC restructures the program into **four layers**, and puts
**all storage/durability/replication into the bottom layer (L0)** so the
layers above inherit it:

| Layer | Role | Analog | Depends on |
|---|---|---|---|
| **L0** | **Replicated object store** — durable, replicated, immutable-part storage + index | VictoriaMetrics/Logs storage engine **over** S3/GCS-grade object storage | (the object store) |
| **L1** | **Streaming / subscriptions** — the NATS takeover (event log, delivery, ordering) | NATS JetStream / Kafka | L0 |
| **L2** | **KV** — low-latency key/value + coherence state | Redis / NATS-KV | L0 |
| **L3** | **Append-log SQL** — queries over the event/log columns | Postgres / ClickHouse / LogsQL | L0 (+ L1 order) |

**L0 resolves the HA/RF debate.** If durability + replication come from a
replicated **object store** (multi-region / erasure-coded, S3/GCS-grade), then
a per-shard writer's local data is a **hot cache**, not the source of truth —
so writers become **fungible** (any node cold-loads sealed parts from the
object store and resumes), and the per-shard **Raft log-replication build
disappears**. What remains at L1 is a lightweight **ordering lease** (who
sequences shard N right now), not consensus over a replicated log. That is a
categorically smaller, safer story than T-RF (§2.5).

**Build L0 first** (explicit sequencing call). L1/L2/L3 are gated behind L0
maturity — none of them is durable without it.

---

## 1. The layered model

- **L0 — replicated object store.** The one place durability, replication,
  retention, compaction, and indexing live. Stores immutable parts (event-log
  columns, KV, metrics) + content-addressed blobs, on a replicated object
  store, with a hot local tier for latency. Everything above is a *view* over
  L0 that can be rebuilt by re-reading L0.
- **L1 — streaming (the NATS takeover).** The event log, per-shard ordering,
  change-feed, consumer groups, ack/redelivery, and the (c) one-hop delivery —
  now **stateless over L0** (state is in L0's replicated parts). See
  [`ehdb-nats-takeover-plan.md`](./ehdb-nats-takeover-plan.md) for the delivery
  design; §2.5 here replaces its HA section.
- **L2 — KV.** Coherence state (chain heads, exec descriptors,
  subscription-circuit), leases, cursors — point lookups served from L0's
  in-memory tier + parts, index-pruned. Replaces NATS-KV (Phase-8 `KvStateDriver`
  is the seed).
- **L3 — append-log SQL.** Read queries over the columnar event/log parts +
  the inverted index (LogsQL/ClickHouse-shaped), the durable home of the
  ai-meta#178 query interface and the projection read-models.

---

## 2. L0 object-store design (on the VM / VictoriaLogs model)

### 2.1 The VM engine principles L0 adopts (cited, accurate)

VictoriaMetrics' storage engine (and VictoriaLogs, its log-tuned sibling) is
the reference. The principles transfer directly:

- **Buffered flush → immutable parts.** Ingest lands in a per-CPU in-memory
  buffer → converted to an **`inmemoryPart`** (size/time trigger) → flushed to
  disk **`smallParts`** every `-inmemoryDataFlushInterval` (default 5 s, with
  `fsync`) → merged into **`bigParts`**. Parts are **immutable once written**;
  any change is a new merged part.
  ([vmstorage retention/merging](https://victoriametrics.com/blog/vmstorage-retention-merging-deduplication/))
- **Background tiered merge/compaction.** Event-driven (fires as part count
  grows), merge multiplier ≈ 7.5 (up to 15 parts at once), run **independently
  per partition** (VM: per-month; VictoriaLogs: per-day). Retention = **drop
  whole partitions**, not row deletes. (same source)
- **Inverted index queried FIRST (IndexDB).** Label/field `value → id`
  (metricID/TSID) inverted index; a query resolves matchers → id set → only
  then reads the matched parts/blocks. Global + per-day index; modern VM
  (v1.133+) makes IndexDB **per-partition**.
  ([IndexDB](https://victoriametrics.com/blog/vmstorage-how-indexdb-works/))
- **Columnar on-disk + high compression.** Each part stores columns in
  separate files (`timestamps.bin`, `values.bin`, …); delta-of-delta
  timestamps + a Gorilla-like value transform + **zstd** per block.
  ([compression](https://faun.pub/victoriametrics-achieving-better-compression-for-time-series-data-than-gorilla-317bc1f95932))
- **VictoriaLogs is the closer reference for EHDB's event/log data.** Same
  inmemory→parts→merge skeleton, but **per-day partitions**, **streams**
  (`_stream` low-cardinality field-sets kept contiguous, sorted by `_time`),
  **per-field columnar** (each field its own `values.binN` + a **bloom filter**
  `bloom.binN`; the big `_msg` field isolated into its own files), ~2 MiB
  blocks, bloom filters as a cheap pre-filter before any values are read.
  ([VictoriaLogs columnar storage](https://victoriametrics.com/blog/victorialogs-internals-columnar-storage-on-disk/))
- **No WAL, by design.** VM has no write-ahead log: buffer in RAM → atomic
  fsync-flush to an immutable part; recovery = reopen the last durable parts.
  The stated tradeoff: a hard crash loses the **last few seconds** of
  un-flushed in-RAM data.
  ([no-WAL](https://valyala.medium.com/wal-usage-looks-broken-in-modern-time-series-databases-b62a627ab704))

### 2.2 The honest departure — VM keeps the hot path on LOCAL DISK

**This is the load-bearing correction, and it must not be glossed.** The
user's model — "flushed parts pushed to the replicated object store for
durability+replication" — is **not VM's actual architecture.** In open-source
VM *and* VictoriaLogs:

- The **hot path is local block storage** (`-storageDataPath`); the FAQ
  explicitly contrasts this with Thanos ("Thanos stores data in object
  storage… VictoriaMetrics stores data in block storage").
  ([FAQ](https://docs.victoriametrics.com/victoriametrics/faq/))
- **Object storage is backup-only** (`vmbackup`/`vmrestore` to S3/GCS/Azure).
  ([vmbackup](https://docs.victoriametrics.com/victoriametrics/vmbackup/))
- A **native object-storage tier for live parts is an open, unbuilt roadmap
  item** — even for VictoriaLogs
  ([roadmap](https://docs.victoriametrics.com/victorialogs/roadmap/),
  [VictoriaLogs#48](https://github.com/VictoriaMetrics/VictoriaLogs/issues/48)),
  and cold/object-store tiering for VM is still a feature request
  ([VM#7035](https://github.com/VictoriaMetrics/VictoriaMetrics/issues/7035)).
- VM's own durability is **local disk × cluster `-replicationFactor` + periodic
  backup**, not object storage.

**So EHDB L0 is VM's *engine* + a durability tier VM does not itself ship.**
That is defensible and is exactly what resolves our HA debate — but be clear:
the "immutable parts flushed to a replicated object store as the *live
durability tier*" is **EHDB going beyond VM into VM's own unsolved roadmap
space.** It is the highest-design-risk piece of L0, not a copy of a proven
model. We adopt VM's engine principles (parts/merge/index/columnar) as proven,
and treat object-store-as-durability-tier as **net-new engineering** with the
design risks in §2.3.

### 2.3 Hot-local / durable-async tiering (the low-latency composite)

The composite that gives both low latency and object-store durability:

```
append → in-memory buffer  ─(latency: served immediately)
        → sealed immutable part on LOCAL disk (hot tier, page-cache-friendly)
        → async uploader ships the sealed part to the REPLICATED OBJECT STORE (durable/replicated tier)
read  → merge across { in-memory buffer, local parts, object-store parts } for the id+range
```

- **Hot path never blocks on object-store latency** — writes and recent reads
  hit RAM + local parts (single-digit ms); the object-store upload is
  background. This composes with L1's (c) one-hop delivery: the writer serves
  the change-feed from its hot tier; durability rides along asynchronously.
- **The durability-window knob (must decide).** VM buys speed by *not* fsyncing
  per append (only on the 5 s flush) — accepting a "lose the last few seconds
  on hard crash" window. For an **event log that is the source of truth**, that
  window is more dangerous than for metrics. EHDB's #254 already **fsyncs per
  append** (durable-immediately, ~3.9 ms/append measured, ai-meta#254 perf).
  Two viable postures:
  - **(A) fsync-per-append to the local part** (EHDB's current strength) → the
    local part is durable before ack; the object-store upload adds
    geo-replication. Local disk loss between append and upload is the only
    residual window, and the DB `claim_command` gate + reconcile already cover
    re-drive. **Recommended for L1's event log.**
  - **(B) VM-style buffered flush** (no per-append fsync) → faster, larger
    crash window; acceptable for L2 metrics/derived data, **not** for the
    source-of-truth event log.
  L0 should support **both per-tier** (event-log tier = A; metrics/derived
  tiers = B), matching VM's own posture where it can afford it.

### 2.4 Generalize by data type — do NOT force everything into the metrics layout

VM's model is a **poor fit for large opaque blobs** (they don't tokenize for
blooms, don't delta/zstd-compress well, and blow past page-cache-friendly part
sizing). VictoriaLogs itself isolates its one big field (`_msg`) into dedicated
files for exactly this reason. So L0 carries **three storage shapes** behind
one catalog/URN namespace, each mapped to its data:

| L0 data shape | Model | Serves |
|---|---|---|
| **Append/event columns** | VictoriaLogs-style: streams + per-field columnar parts + bloom pre-filter + inverted index | the event log (L1), projection read-models (L3), audit |
| **KV / small values** | small parts + index, latest-value-per-key; in-memory tier for point reads | coherence state, leases, cursors (L2) |
| **Metrics / numeric series** | VM-style: TSID index + Gorilla+zstd columns | platform telemetry, lag/backpressure series |
| **Blobs (large, opaque)** | **content-addressed object mapping** — bytes stored whole in the object store, keyed by digest; L0 holds only **metadata + pointer** (NOT columnar, NOT chunked into parts) | Arrow-IPC state shards (#166/#104), result-tier payloads, artifacts |

The blob shape is deliberately **not** VM-shaped — it is a plain
content-addressed object map (which EHDB's Phase-8 object tier already is,
§3). This is the "don't force blobs into a metrics layout" requirement, made
explicit.

### 2.5 HA resolution — L0 object-store replication SUPERSEDES per-shard Raft (T-RF)

With L0, the takeover doc's deferred **T-RF** (per-shard Raft log replication +
leader election for writer HA) is **no longer the plan**:

- **Durability + replication come from the object store** (multi-region /
  erasure-coded), not from replicating a per-shard log across pods. A shard
  writer's local parts are a hot cache; sealed parts live durably+replicated in
  L0.
- **Writers become fungible.** On writer death, another node **cold-loads the
  sealed parts from L0** and resumes — no consensus, no PVC hand-off, no log
  re-replication. This is the VM "restore from durable storage" recovery,
  except the durable storage is a live replicated object store rather than a
  backup.
- **What remains is a light ordering lease.** The one thing the object store
  does *not* give is a global/per-shard **sequence** — so L1 keeps a
  per-shard **sequencer lease** (a lock/lease naming the current sequencer for
  shard N), which is a small, well-understood primitive (a lease over L0 or a
  coordination KV), **not** a replicated consensus log. Ordering is preserved
  because only the lease-holder sequences; on failover the lease moves and the
  new holder resumes from the last sealed part's sequence.
- **Residual window** (unchanged from §2.3): appends in the in-memory buffer /
  local part not yet uploaded to L0 are only as durable as the local node until
  the upload lands. Posture (A) fsync + the DB claim gate bound the blast
  radius; the object store bounds geo-durability.

Net HA story: **shards-only + fungible writers over a replicated object store**
— parity-plus with today's single NATS, **without** the quarters-long
consensus build. The takeover completes when NATS is deleted (L1 cutover on a
mature L0); the "T-RF" line item is retired, replaced by "L0 object-store
replication + L1 ordering lease."

---

## 3. Reuse assessment — what EHDB already has vs. the real gap

EHDB is further along toward L0 than a greenfield estimate would suggest,
because #254 and the Phase-8 tiers already embody several VM principles.

| VM/L0 principle | EHDB today | Gap to build |
|---|---|---|
| **Immutable parts** | **Strong.** #254 `DurableSegmentStore` writes append-only **immutable `seg-*.eslog` segments** (8 MiB rollover, `DEFAULT_SEGMENT_MAX_BYTES`), archivable/GC'able/replicable (`durable_eventlog.rs`). Segments ≈ VM parts. | Rename/reshape "segment" → "part" semantics; per-partition grouping (by day/shard) rather than one growing chain. |
| **Buffered flush → parts** | **Partial/opposite.** #254 **fsyncs per append** (durable-immediately), not VM's buffer-then-flush. | The in-memory-buffer → periodic-flush hot tier (posture A/B knob, §2.3). Reuses the fsync strength for the event log. |
| **Background tiered merge (small→big)** | **Weak.** #254 has segment rollover + **GC/retention** (slices 7/8, keep-last-N, ehdb#271) but **no small→big merge/compaction engine**. | The merge engine (VM's core). Net-new. |
| **Inverted index (IndexDB), queried first** | **Weak.** #254 has an **offset index** (`global_sequence → (segment, byte offset)`) — a sequence→location map, **not** a `value→id` inverted index. The catalog models "indexes / data-skipping metadata" but the reference is minimal. | The inverted index + index-first query pruning + blooms. **The biggest single gap.** |
| **Columnar per-field + blooms** | **Partial.** Arrow IPC/Feather columnar exists for the **result/state tiers** (#104/#166, `arrow_codec`) and blobs; the **event-log segments are row-oriented framed records**, not per-field columns. | VictoriaLogs-style per-field columnar + bloom for the event/log tier. |
| **Object-store durability tier + cold-load** | **Partial (the seam exists!).** `durable_eventlog_shared.rs` already **ships sealed segment bytes to a shared store** and lets a non-owner **cold-load + replay**; `ehdb-storage` has S3/GCS/Azure adapter designs; content-addressed `ImmutableObjectStore`. | The **async part-uploader + read-merge across local+object-store parts**, and making the object store the *live* durability tier (not backup). This is the §2.2 net-new, highest-risk piece. |
| **Blob content-addressed mapping** | **Strong.** Phase-8 **`ObjectBlobDriver`** stores blobs content-addressed (`objects/sha256/<hex>`) with a logical-key→digest registry — exactly the §2.4 blob shape. | Little — wire it as L0's blob shape. |
| **KV latest-value + CAS/TTL** | **Strong.** Phase-8 **`KvStateDriver`** (per-key subject, latest-record-wins, CAS/TTL superset). | Point-read latency tier (in-memory) for L2. |
| **Projection / read-models** | **Strong.** Phase-7 `ProjectionDriver` (primary merged) materializes read-models off the log tail. | Becomes the L3 read layer over columnar parts. |
| **Replication substrate** | **External.** Replication comes from the **object store** (GCS/S3), not EHDB consensus — which is the plan (§2.5). Raft was always deferred/non-goal (`Architecture.md:961`). | None in EHDB — inherit from the object store. |

**Bottom line:** the **immutable-part, blob-mapping, KV, projection, and
shared-store-shipping** pieces are substantially present (#254 + Phase-7/8).
The **real net-new for L0** is three things: **(1) the inverted index +
index-first pruning** (the biggest gap), **(2) the background small→big merge
engine**, and **(3) making the object store the live async-durability tier**
(the §2.2 beyond-VM piece) with columnar-per-field for the event tier. That is
a focused, nameable build — not a from-scratch storage engine.

---

## 4. Re-sequenced roadmap + per-layer cost

**L0-first; each higher layer gated behind L0 maturity.**

### L0 — replicated object store (BUILD FIRST)

- **L0.0 — part model.** Reshape #254 segments into **partitioned immutable
  parts** (by shard/day) with the checkpoint/offset index; keep fsync-per-append
  (posture A). *Reuse: #254.*
- **L0.1 — async object-store durability tier.** The part-uploader (sealed part
  → replicated object store) + read-merge across local + object-store parts +
  cold-load-on-miss. *Reuse: `durable_eventlog_shared.rs` + `ehdb-storage`
  adapters.* **This is the §2.2 net-new, highest-risk slice → the first build
  slice, §5.**
- **L0.2 — inverted index.** `value→id` IndexDB + index-first pruning (+ blooms
  for the log tier). *Net-new; the biggest gap.*
- **L0.3 — background merge engine.** small→big part compaction, per-partition,
  event-driven. *Net-new.*
- **L0.4 — columnar-per-field for the event/log tier** (VictoriaLogs-style) +
  the blob shape wired from Phase-8. *Reuse: Arrow codec, Phase-8 object tier.*
- **L0.5 — retention as drop-partition** + tiered GC. *Reuse: #254 GC slices.*

**L0 cost: ~2–4 quarters** (a production storage engine; the reference pieces
exist but index + merge + object-store-tier are real builds). L0 is the gate.

### L1 — streaming / NATS takeover (gated behind L0)

The (c) delivery design in [`ehdb-nats-takeover-plan.md`](./ehdb-nats-takeover-plan.md)
**minus its HA section** (superseded by §2.5). Now **cheaper**: durability/HA
come from L0, so L1 builds **per-shard ordering lease + change-feed + one-hop
delivery + consumer-group/ack + KEDA `prometheus` lag**, over fungible writers.
**Revised L1 cost: ~1.5 quarters** (down from ~2q — the per-shard PVC/Raft work
moves to L0's object-store inheritance). Gated: L1 cutover (delete NATS) only
on a mature L0 (durability proven).

### L2 — KV (gated behind L0)

Coherence state + leases + cursors on L0's KV shape + in-memory point-read tier.
Replaces NATS-KV. *Reuse: Phase-8 `KvStateDriver`.* **~1 quarter.**

### L3 — append-log SQL (gated behind L0, uses L1 order)

LogsQL/ClickHouse-shaped read queries over the columnar event parts + inverted
index; durable home of the #178 query interface + projection read-models.
**~2–3 quarters** for real SQL; read primitives come from L0.

**Program total is multi-year**; the point of L0-first is that **every layer
above is undurable until L0 exists**, so L0 is the correct and only sensible
first investment.

---

## 5. FIRST L0 BUILD SLICE — L0.1 async object-store durability tier (spec; do NOT build)

This replaces the old T0 as the concrete next step. It targets the
**highest-risk, most-load-bearing** L0 piece: proving the hot-local /
durable-async composite (§2.3) works — because that is what the whole layered
model rests on and the part VM itself has not shipped.

**Name:** L0.1 — async part-uploader + read-merge over local + replicated
object store, SHADOW, on #254 segments.

**Goal / what it proves:** a writer can **append to a local immutable part
(fsync, hot, single-digit ms), asynchronously upload sealed parts to a
replicated object store, and serve reads by merging local + object-store
parts** — such that (a) the hot path never blocks on object-store latency, and
(b) a **fresh node with no local data can cold-load the parts from the object
store and reproduce the exact log** (the fungible-writer / durability
property that retires T-RF). All **shadow**: the authoritative path
(NATS/JetStream + Postgres, or the existing #254 pod-local log) is untouched.

**Scope (build):**
1. **Part-uploader (shadow).** On #254 segment seal (rollover), upload the
   immutable segment to a configured object store
   (`ehdb-storage` GCS/S3 adapter) under a deterministic key; behind
   `NOETL_EHDB_L0_UPLOAD=off|shadow` (default off).
2. **Read-merge + cold-load.** A read path that reconstructs the log by merging
   local segments + object-store segments after a cursor; and a **cold-load
   mode** that reads *only* from the object store (no local data) and replays
   to the same in-memory index.
3. **Latency + durability instrumentation.** Secret-free metrics: append p99
   (must stay hot/local, unaffected by upload), upload lag (seal→object-store
   durable), and a **cold-load correctness check** (a fresh store cold-loaded
   from the object store yields byte-identical records + the same global
   sequence as the origin).

**Explicitly OUT:** the inverted index (L0.2), the merge engine (L0.3),
columnar-per-field (L0.4), any L1 delivery, any NATS change, any prod/GKE. This
slice is *only* the object-store durability tier + cold-load.

**Exit criteria (kind, authoritative path untouched):**
- **Hot-path isolation:** append p99 with `L0_UPLOAD=shadow` is within noise of
  `off` — the async upload does **not** regress append latency (the core §2.3
  claim).
- **Durability:** every sealed part lands in the object store; upload lag is
  bounded and observable.
- **Cold-load correctness:** a fresh store with an empty local dir, pointed at
  the object store, **cold-loads and reproduces the exact record set + global
  sequence** of the origin (the fungible-writer property — proves L0 replaces
  T-RF).
- **Reversibility:** `L0_UPLOAD=off` ⇒ byte-identical `/metrics` + behavior;
  pod-local #254 path unchanged.
- **Boundary:** data-plane worker/system role only; no control-plane EHDB
  access; secret-free metrics.
- **No prod/GKE; kind-only.**

**Why L0.1 and not L0.0 first:** L0.0 (part reshape) is low-risk refactoring of
#254; L0.1 proves the **novel, beyond-VM** claim (object store as a live
durability tier that doesn't cost hot-path latency) on which the HA resolution
(§2.5) and the whole layered bet depend. Prove the risky thing first.

---

## 6. Decisions

**Locked (2026-07-15):** (1) layered platform, **L0-first**; (2) L0 engine
modeled on **VM/VictoriaLogs principles** (with the §2.2 object-store
departure); (3) **HA via L0 object-store replication + L1 ordering lease** —
the per-shard-Raft "T-RF" plan is **retired/superseded**.

**Open (need the user):**
- **6.1 — L0 durability-window posture** (§2.3): confirm fsync-per-append
  (posture A) for the event-log tier vs VM-style buffered flush (B) for
  derived/metrics tiers. *Recommendation: A for L1's log, B allowed elsewhere.*
- **6.2 — The replicated object store** itself: which backend is L0's
  durability tier (GCS multi-region? S3 + erasure? in-cluster MinIO/Ceph?), and
  its replication/consistency guarantees — this is now the platform's
  durability foundation, so the choice is load-bearing.
- **6.3 — L1 latency budget** (carried from the takeover doc): the drive-hop
  p99 that gates the L1 cutover; still needs a number.
- **6.4 — Scope confirmation:** L0 is a ~2–4 quarter storage-engine build
  before L1 (NATS removal) can even begin its cutover. Confirm the sequencing
  is acceptable (NATS stays fully in place throughout L0).

---

## Related

- [`ehdb-nats-takeover-plan.md`](./ehdb-nats-takeover-plan.md) — the L1
  streaming design ((c) one-hop delivery); **its HA/T-RF section is superseded
  by §2.5 here.**
- [`nats-vs-ehdb-transport-boundary.md`](./nats-vs-ehdb-transport-boundary.md)
  — the code-cited NATS role inventory.
- `ehdb-wiki/Design-Event-Log-Core-Engine.md`, `Design-Durable-EventLog-Backend.md`,
  `Design-KV-Object-Vector-Engines-Phase-8.md`, `Design-Projection-Read-Model-Engine.md`,
  `Design-Performance-and-Load-Testing.md` — the EHDB tiers L0 reuses.
- VM/VictoriaLogs sources (see §2 inline citations):
  vmstorage retention/merging, IndexDB, VictoriaLogs columnar storage, no-WAL,
  FAQ (object storage = backup only), VictoriaLogs roadmap (object-store tier
  is an open item).
- Program tracker: noetl/ai-meta#194.
