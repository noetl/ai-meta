# RFC: EHDB as a Layered Platform (L0→L3) — L0-First

> ## ⛔ PROGRAM INVARIANT — EHDB is NOT a general-purpose database
> **EHDB is a noetl-centric internal store. It exists solely to hold the
> internal information noetl requires to operate, over a FIXED set of
> predefined datasets (§0.1).** It is NOT a hosted/user-facing database.
>
> **Operations & references, never payloads (the sharpened boundary).** EHDB
> stores noetl's own **control-plane metadata** (executions, events, commands,
> catalog, runtime registration) and the **data-plane operational state of
> worker workloads** (operation state, references/pointers, coherence/KV). It
> does **NOT** store the actual data a playbook processes. **Playbook payload /
> business data flows through connectors** to user-defined systems (Postgres,
> object stores, Redis, Kafka, …). EHDB holds the *operations and references*,
> never the *payloads*. A dataset that would hold a business payload inline is a
> boundary violation — it must hold a **reference** and let the payload live in
> the user's system via a connector (see §0.2 for the per-dataset audit).
>
> Consequences, binding on every layer L0→L3:
> - **Optimize for noetl's known access patterns** — fixed sort keys, fixed
>   prunable dimensions, hand-coded resolution paths per dataset.
> - **Do NOT build general-database features:** no arbitrary user schemas, no
>   general SQL DDL (`CREATE`/`ALTER`), no cost-based query planner, no
>   secondary indexing on arbitrary columns, no multi-tenant hosted-DB surface.
> - **Business/domain data is NEVER in EHDB** — it stays in external systems
>   reached by playbook connectors (unchanged from the coupling RFC).
> - This invariant is a **scope guardrail: it SHRINKS each layer's design**
>   (see §2.6 for what it cuts). When a layer's design grows toward generality,
>   that is the smell that this invariant is being violated.
> - The external Flight-SQL surface (ai-meta#178/#184) is a **read-only export
>   of noetl's own data**, not a general DB — keep that framing.

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

### 0.1 The FIXED predefined dataset set (the whole scope of EHDB)

EHDB stores **exactly these** noetl-internal datasets — enumerated from the
`noetl.*` schema (`agents/rules/data-access-boundary.md`) + the EHDB tier map
(coupling RFC). Each has a **fixed schema, a fixed sort key, and a fixed set of
access patterns** — the properties that let L0 be purpose-built (§2). Adding a
dataset is a deliberate, compiled-in change, never runtime DDL.

| # | Dataset | Source | Sort/lookup key | noetl access patterns (the ONLY ones) |
|---|---|---|---|---|
| D1 | **Event log** (append-only execution events) | `noetl.event` | `global_sequence`; scoped by `execution_id` | append; range-scan after seq; per-execution replay |
| D2 | **Command queue** | `noetl.command` (+ `noetl.outbox`) | `command_id` / `event_id` | enqueue; claim-by-id; unclaimed scan |
| D3 | **Execution / projection read-models** | `noetl.execution` + `projection_snapshot` | `execution_id`; `event_id` | get-state-by-execution; get-event; list-executions |
| D4 | **KV / coherence state** | chain heads, exec descriptors, subscription-circuit, leases, cursors | `key` | get/put latest; CAS; prefix-scan |
| D5 | **Object / blob** | state shards (#166), result tier (#104), Arrow-IPC, artifacts | content digest / logical key | put (content-addressed); get-by-key; prefix-list |
| D6 | **Vector / RAG** | platform docs, chunks, embeddings | `(collection, point_id)` | upsert; top-k cosine; delete |
| D7 | **Catalog** | `noetl.catalog` (playbooks, tools, resources, snapshots, ACLs) | catalog id / path | get-by-id; list; snapshot |
| D8 | **Runtime registration** | `noetl.runtime` | worker id | register/heartbeat; list-live |
| D9 | **System WASM library store** | module manifests + env/channel bindings | `(path, channel, env)` | publish; bind; resolve |
| D10 | **Facts / provider-state** (#189) | provider facts folded over the event log | `(stack, provider_urn)` | fold; get-latest-fact; drift-scan |

Out of scope for EHDB: **secret values** (`noetl.credential` / `noetl.keychain`
stay in the keychain — EHDB holds at most alias references), and **all
business/domain data** (external systems, forever). That is the entire dataset
universe; there is no "arbitrary table" case to design for.

### 0.2 Boundary audit — operations-&-references vs payloads (code-verified 2026-07-15)

A read-only audit of D1–D10 against the sharpened boundary (EHDB holds
operations + references, never payloads). **5 clean; 4 boundary-risk sharing one
root cause; 1 clean-today-with-a-latent-seam.**

| Dataset | Verdict | Why (code) |
|---|---|---|
| **D1 events** | ⚠️ **boundary-risk** | Step result rides **inline** in the `call.done` event when `≤ INLINE_CONTEXT_MAX_BYTES = 100 KB` (`worker/src/executor/command.rs:1493`); a `result_ref` URN only when larger (`:1562`). So small **business** results sit inline in the durable append-only log. |
| **D2 commands** | ⚠️ **boundary-risk (minor)** | Command **input** carried inline as `serde_json::Value`, no size-tiering (`server/src/handlers/execute.rs:1218`). Business step input can ride inline. |
| **D3 projections** | ⚠️ **boundary-risk** | Slim chain **deliberately keeps `context` + `result`** (`SLIM_EVENT_KEYS`, `worker/src/state_builder.rs:128`), so it mirrors D1's inline small payloads (the drive reads result fields for `when:`/`set:`). |
| **D5 object/blob** | ✅ **large: in-scope** / ⚠️ **small: see D1** | Large results (>100 KB) are externalized reference-only — URN in state, bytes in an **object-store byte-source** (`command.rs:1591`, `result_materializer.rs:399`, URN grammar `result_locator.rs:109`). This **honors reference-only-state** and matches the accepted "payload → byte-source" shape. The residual exposure is the ≤100 KB inline path (D1/D3), not the large-payload tier. |
| **D4 KV/coherence** | ✅ in-scope | Operational only — circuit-breaker state, leases, CAS keys (`worker/src/ehdb/kv.rs:7,566`). No business payload. |
| **D6 vector/RAG** | ✅ **in-scope today; latent seam** | Platform RAG only (system docs / catalog embeddings), control-plane-guarded (`worker/src/ehdb/rag.rs:241`), ingest is **lexical not embedding**, and **no playbook `tool:` is wired to `rag::ingest`** (only the diagnostic binary calls it). BUT `rag::ingest` is role-permissive (`rag.rs:301`) — if a future playbook tool were wired to it, **user documents could land in the platform tier**. Guardrail below. |
| **D7 catalog** | ✅ in-scope | noetl's own playbook/tool/resource definitions (control-plane). |
| **D8 runtime** | ✅ in-scope | Worker registration / heartbeat (`server/src/handlers/runtime.rs`). |
| **D9 system-WASM** | ✅ in-scope | Immutable module manifests + bindings (platform code refs). |
| **D10 provider-facts** | ✅ in-scope | Infra operational state about the user's cloud, **secrets scrubbed** (`redact_sensitive`, `tools/src/tools/provider.rs:45`); records resource state/ownership, not business payload. (Fact-writer currently in an unmerged worktree.) |

**Root cause (D1/D2/D3/D5-small are one issue):** the **100 KB inline threshold**
(`command.rs:1493`) lets small step **payloads** ride inline in the durable
event log + slim projection + command input, instead of being reference-only.
Large payloads already do the right thing (URN + byte-source).

**Recommended fixes — RECORDED for routing as their own slices; NOT applied
here (this pass is read-only on the datasets):**

- **Slice A — reference-only for small payloads too (D1/D3/D5).** Make the
  event/projection carry a **URN + the bounded `extracted` predicate block**
  only, for *all* result sizes — drop the 100 KB inline payload from the
  durable log. Payload (any size) lives in the byte-source (the operational
  object tier — rebuildable, GC'd — or a user connector for genuinely business
  data). Removes business payload from D1/D3. Root: `command.rs:1493`,
  `state_builder.rs:128`.
- **Slice B — tier command input (D2)** the same way results are tiered, so
  business input isn't carried inline untiered. Root: `execute.rs:1218`.
- **Slice C — guardrail for D6 (no code today, keep it that way):** the platform
  vector/RAG tier stays **system-docs / catalog-embeddings only**; **do NOT wire
  a playbook user-document ingest tool to `rag::ingest`.** User-document RAG is
  business data → it goes to the user's own vector store (pgvector / Qdrant) via
  a connector, never the platform tier. Keep the vector-upsert hook unwired for
  user data.

**Framing note:** the object-store **byte-source** holding large payloads is the
operational **state-vehicle** (Arrow-IPC, scoped to `execution_id`+step,
rebuildable from the log, GC'd) — that is *operational state*, not a durable
business-data store, so it is in-scope. The sharp line the audit draws is
**inline business payload in the durable control-plane datasets** (D1/D3, small
results; D2, input) — that is what Slices A/B remove.

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
- **L3 — fixed read queries + read-only export** (NOT a general SQL engine —
  §2.6). The fixed set of reads noetl's control plane makes (list executions,
  get execution state, get event, provider-facts) over the projection
  read-models + the §2.5 catalog, plus the ai-meta#178/#184 **read-only**
  Flight-SQL export of those same datasets. No planner, no DDL.

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

### 2.5 ClickHouse-style meta-catalog — manifest + sparse index → object-store pointer

VM's engine writes the parts; it does **not** give a good *table format over
object storage* (VM's IndexDB is per-series label→id, tuned for millions of
arbitrary series). Because noetl's datasets are **predefined** (§0.1), L0 adds a
purpose-built **ClickHouse-MergeTree-style meta-catalog** — the "table format
over object storage" pattern (conceptually Iceberg/Delta manifests + ClickHouse
part-metadata), but with **fixed, compiled-in schemas**, no DDL, no planner.

**Two lightweight structures per dataset (both small, cached in RAM, themselves
durable objects in the object store):**

1. **Manifest** — the list of parts that exist and **where** they are. One row
   per immutable part:
   `{ part_id, partition (shard/day), min_key, max_key, record_count,
   byte_size, object_store_uri }`. This is the Iceberg-manifest / ClickHouse
   `system.parts` analog — the pointer catalog VM lacks. It is versioned
   (append a new manifest version on seal/merge; old versions GC'd) so readers
   see a consistent snapshot.
2. **Sparse primary index per part** — one entry per **granule** (block) over
   the dataset's **fixed** sort key → the granule's **mark** (compressed byte
   offset within the part). ClickHouse `primary.idx` + `.mrk`. Plus a per-part
   **min/max** of the sort key for range pruning (ClickHouse MinMax skip index).

**Lookup resolution — a fixed, compiled path per dataset, no scan, no planner.**
Worked example, D1 event log ("events for execution E after `seq` S"):

1. **Manifest prune** — select only parts whose `partition == shard_for(E)` and
   whose `[min_key, max_key]` overlaps `[S, ∞)`. All other parts are skipped
   with **zero I/O** (pointer catalog only).
2. **Sparse index** — in each surviving part, binary-search the sparse primary
   index to the granule containing `S`.
3. **Ranged read** — resolve the granule's mark to a byte range and issue a
   **ranged GET** against the part's `object_store_uri` — fetch *only that
   block*, not the whole part.
4. **Decode** the columnar block; return.

**Composition with VM + the object store:** VM's buffer→parts→merge produces the
immutable parts and, on **seal/merge**, writes each part's sparse index +
min/max and appends a new **manifest** version; the async uploader (§2.3) ships
the part to the object store and the manifest records its URI. A reader consults
the manifest (RAM/cached) → prunes → ranged-GETs the exact blocks from the
object store. The manifest is what makes "recent = local part, older = object
store" transparent: same pointer catalog, different `object_store_uri` vs local
path. Because every dataset's sort key + manifest schema are **fixed** (D1 by
`global_sequence`, D4 KV by key-hash, D6 vector by `(collection,point_id)`, …),
these structures are **generated per dataset, not discovered at runtime** — no
arbitrary index, no catalog service.

### 2.6 What the noetl-only scope CUTS (the invariant shrinks every layer)

The §0-invariant is a **subtraction**. Concretely, versus a general database:

| General-DB feature | EHDB (noetl-only) | Effect |
|---|---|---|
| Cost-based **query planner** | **CUT** — fixed compiled resolution path per dataset (§2.5) | L3 shrinks to wiring, not an optimizer |
| Arbitrary **schemas / DDL** (`CREATE`/`ALTER`) | **CUT** — 10 compiled-in schemas (§0.1); changes are migrations | no catalog/DDL engine |
| **Secondary indexing on arbitrary columns** / high-cardinality label index | **CUT** — inverted index built ONLY for each dataset's **fixed** prunable dims (D1: `execution_id`, `event_type`; D5: key; not arbitrary) | **the "biggest gap" (§3) collapses** from a general IndexDB to a handful of fixed indexes |
| VictoriaLogs **full-text bloom over arbitrary fields** | **CUT** — blooms only on the specific fields noetl filters on | far less index to build/maintain |
| General **SQL surface** | **CUT** — L3 = the fixed read queries noetl's control plane makes + the **read-only** ai-meta#178/#184 export | not a SQL engine |
| **Multi-tenant hosted-DB** / user-facing surface | **CUT** — tenant/namespace is noetl's own isolation only | no DB-as-a-product surface |
| General **merge/compaction policy** | **CUT** — per-dataset fixed (D1 merge by seq-range; D4 compact-to-latest-per-key) | simpler mergers |

**Two shrinks worth calling out — and a recommended cut:**

- **The inverted index (§3's "biggest gap") is much smaller than it looked.**
  It is not a general VictoriaLogs IndexDB — it is a *few fixed per-dataset
  indexes* on known dims (execution_id, event_type, key, collection). This
  materially de-risks L0.2.
- **L3 should be CUT from "append-log SQL engine (Postgres-like)" to "fixed
  read paths + read-only export."** The prior L3 framing carried a
  general-SQL/planner ambition that this invariant forbids. **Recommendation:
  drop the SQL-engine ambition** — L3 becomes (a) the fixed read queries the
  control plane already makes (list executions, get execution state, get event,
  provider-facts) served off the projection read-models + the §2.5 catalog, and
  (b) the ai-meta#178/#184 **read-only** Flight-SQL export of those same fixed
  datasets. That drops L3 from ~2–3 quarters to **~1 quarter** (mostly wiring
  existing Phase-7 projection reads + the export surface), and removes a query
  planner from the program entirely.

### 2.7 HA resolution — L0 object-store replication SUPERSEDES per-shard Raft (T-RF)

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
| **Meta-catalog (manifest + sparse index → pointer) + index-first pruning** | **Weak.** #254 has an **offset index** (`global_sequence → (segment, byte offset)`) — a sequence→location map, not the manifest/sparse-index catalog (§2.5), and no `value→id` index. | The §2.5 ClickHouse-style manifest + sparse index + a **few fixed per-dataset** inverted indexes (NOT a general IndexDB — §2.6 shrinks this). Still the largest gap, but bounded. |
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
- **L0.2 — meta-catalog + fixed indexes.** The §2.5 manifest + sparse primary
  index + min/max pruning, plus a **few fixed per-dataset** inverted indexes
  (NOT a general IndexDB — §2.6). *Net-new; the largest gap, but bounded by the
  fixed dataset set.*
- **L0.3 — background merge engine.** small→big part compaction, per-partition,
  event-driven, **per-dataset fixed merge policy** (§2.6). *Net-new.*
- **L0.4 — columnar-per-field for the event/log tier** (VictoriaLogs-style,
  columns limited to the fixed dataset schemas) + the blob shape wired from
  Phase-8. *Reuse: Arrow codec, Phase-8 object tier.*
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

### L3 — fixed read queries + read-only export (gated behind L0)

**Scoped down by the invariant (§2.6): NOT a general SQL engine.** The fixed
read queries the control plane makes (list executions, get execution state, get
event, provider-facts) over the Phase-7 projection read-models + the §2.5
catalog, plus the ai-meta#178/#184 **read-only** Flight-SQL export. No planner,
no DDL. **Revised cost: ~1 quarter** (down from ~2–3q — the SQL-engine ambition
is **cut**), mostly wiring existing projection reads + the export surface.

**Program total is multi-year**, but the **noetl-only invariant (§2.6) shrinks
it** — no query planner, no DDL, fixed per-dataset indexes/mergers, L3 cut from
a SQL engine to fixed reads + export (~2–3q → ~1q). The point of L0-first is
that **every layer above is undurable until L0 exists**, so L0 is the correct
and only sensible first investment.

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

**Locked (2026-07-15):** (0) **PROGRAM INVARIANT — EHDB is noetl-internal-only,
a FIXED set of predefined datasets (§0.1), NOT a general-purpose DB**; it
shrinks every layer (§2.6). (1) layered platform, **L0-first**; (2) L0 =
**VM/VictoriaLogs write engine + a ClickHouse-style meta-catalog** (§2.5:
manifest + sparse index → object-store pointer), with the §2.2 object-store
departure; (3) **HA via L0 object-store replication + L1 ordering lease** — the
per-shard-Raft "T-RF" plan is **retired/superseded**; (4) **L3 is NOT a SQL
engine** — fixed read queries + read-only export (§2.6 cut).

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
