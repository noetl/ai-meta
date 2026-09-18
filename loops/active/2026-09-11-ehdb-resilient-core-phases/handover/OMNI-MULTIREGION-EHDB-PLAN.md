# Omni / multi-dimensional / cross-regional EHDB — design + phased plan

**DESIGN ONLY. No prod change, no code change, no merge, no running config touched
by this document.** Written 2026-09-18 against `ehdb@b8b9975`, `server@main`,
`worker@main`, `ops@main` as checked out under `ai-meta/repos/`.

North star: a **globally distributed, multi-region, externally-consistent event
store + serving layer** for NoETL's internal control-plane data, reached by
increments that each ship alone and roll back alone.

## How to read this

Every load-bearing claim is tagged:

- **VERIFIED** — I ran the command or read the cited line in the tree at the SHA
  above.
- **VERIFIED (manifest)** — read from an ops manifest, *not* from a live object.
  Per [`apply-safety.md`](../../../../agents/rules/apply-safety.md) and
  [`representation-drift.md`](../../../../agents/rules/representation-drift.md)
  a manifest is a representation; I did not touch prod to confirm it.
- **ASSUMED** — plausible, untraced. Re-check before relying on it.

The program's recorded failure mode is a confident claim generalised off a
partial read (see the two withdrawn claims in
[`FENCING-SUBSTRATE-BUILD-HANDOVER.md`](FENCING-SUBSTRATE-BUILD-HANDOVER.md)),
so the split is deliberate and the *absence* claims below carry their
denominator.

---

## 1. Ground truth — what EHDB is today

### 1.1 The tier model

Each tier is a three-valued mode, parsed from one env var, defaulting to `Off`
on an unrecognised value (fail-safe). **VERIFIED** at
`worker/src/ehdb/eventlog.rs:86-117` (`EventLogMode::{Off,Shadow,Primary}` +
`from_env`), with the same shape in `kv.rs:88`, `object.rs:100`,
`projection.rs:102`, `vector.rs:96`.

| Tier | Env | Prod mode |
| :-- | :-- | :-- |
| Event log (D1) | `NOETL_EHDB_EVENTLOG` | `primary` — **VERIFIED (manifest)** / recorded in memory index |
| Projection (D3) | `NOETL_EHDB_PROJECTION` | shadow |
| KV (D4) | `NOETL_EHDB_KV` | shadow |
| Object (D5) | `NOETL_EHDB_OBJECT` | shadow |
| Vector (D6) | `NOETL_EHDB_VECTOR` | not deployed |

`PRIMARY_SERVE_ACTIVATED` is a compile-time kill switch present in `eventlog.rs:82`,
`kv.rs:84`, `object.rs:96`. **VERIFIED.**

### 1.2 The write path prod actually traverses

**VERIFIED** and already recorded in [`TRACE-RESULTS.md`](TRACE-RESULTS.md) —
restated because the whole plan below depends on it:

```
worker  tier_query_source.rs:141 resolve() -> Resolution::Service   (prod)
        -> forwarded to noetl-cmdbus-writer-0:9110
writer  tier_service.rs:381  tier_store::append
        tier_store.rs:207    fn driver(..) -> LocalReferenceEventLogDriver  // concrete, NO branch
```

On `Resolution::Service` the worker enters neither `eventlog::mirror_event`
(`metrics_server.rs:1030`) nor `query::run_query` (`metrics_server.rs:392`).
`NOETL_EHDB_EVENTLOG_BACKEND` — the flag that selects `build_durable_stack`
(`worker/src/ehdb/eventlog_backend.rs:505`, constructed at `:609`) — is read by
**neither side** of the production tier path. It is inert for the event-log
tier, not dangerous.

⭐ **Consequence that shapes every phase below: any new durable-write behaviour
must land in `tier_store.rs`, not `eventlog_backend.rs`.** The latter is the
reference implementation to reuse, on a path prod does not take.

### 1.3 The L0 engine — what is already Cockroach-shaped

**VERIFIED** in `ehdb/crates/ehdb-l0/`:

| Primitive | Where | What it already is |
| :-- | :-- | :-- |
| Immutable parts + ClickHouse-style manifest + sparse index + per-granule bloom | `part.rs` (927), `catalog.rs` (438), `bloom.rs` | An LSM-ish sealed-part store with min/max pruning |
| **N-way replica set** | `engine.rs:230 ReplicaTarget`, `:316 open_replicated`, `catalog.rs ReplicaLocation` | Write-once copy of each immutable part to N substrates; reads fall back across them; the manifest *is* the replica-location catalog |
| **No consensus, by design** | `lib.rs:85` — *"**no consensus / no Raft** — the HDFS / block-replication model, not a replicated log"* | The T-RF per-shard-Raft plan is explicitly retired |
| Cold-load / fungible writer | `engine.rs:436`, `lib.rs:64` | A fresh node reproduces the record set + global sequence from the substrate |
| **Failure domains** | `failure_domain.rs` (224) — `FailureDomain::{LocalDevice{device_id},Remote{provider,bucket},Ephemeral,Undeclared}`, `validate_replica_domains`, `L0Config::require_distinct_domains` (`engine.rs:111`) | A zone-config in embryo. `Undeclared` **fails closed** — it is treated as its own unique domain per call, so silence is never read as independence |
| Durability window | `unreplicated.rs` (371) `UnreplicatedTracker` | Per shard, the age of the **oldest acked-but-not-yet-durable** record — measured from *append*, not from *seal* |
| Age-based seal | `engine.rs:96 seal_max_age`, `seal_aged_parts()`; wired by `worker/src/ehdb/eventlog_backend.rs:268 spawn_seal_age_sweep`, called from `command_bus.rs:253` **and** `event_bus.rs:276` | **VERIFIED** — two call sites, both buses |
| Fsync posture | `lib.rs` §durability — `FlushPolicy::EveryAppend` default for D1 | Local durability before ack |

⚠ **A memory-index entry is now stale.** The index says *"`seal_max_age=None`
AND `seal_aged_parts` has no prod caller"*. Both halves are false as of this
tree: there are two call sites (above), and
`ops/ci/manifests/noetl/cmdbus-writer-statefulset-prod.yaml:84` sets
`NOETL_EHDB_SEAL_MAX_AGE_MS: '5000'` — **VERIFIED (manifest)**, not verified
against the live object. The unsealed-tail window is therefore bounded at ~5 s
on the cmdbus writer by config, not unbounded. This matters because §4's closed
timestamp is built on exactly that bound.

### 1.4 Leadership and fencing

**VERIFIED** in `ehdb/crates/ehdb-reference/`:

- `election.rs` (398) — single-writer election over a `LeaseStore` CAS.
  `LeaseRecord{holder, transitions, renewed_at_millis, duration_secs, version}`
  mirrors `coordination.k8s.io/v1` Lease; `transitions` **is** the fencing
  token, monotone by the same CAS that granted the lease. Header: *"Wired, but
  NOT authoritative"* — it issues tokens; exclusion still rests on
  `replicas: 1`.
- `election.rs:23` — *"Why Leases and not Raft: the API server's compare-and-swap
  on `resourceVersion` **is** the mutual exclusion, and etcd behind it already is
  the Raft cluster."*
- `fencing.rs` (404) — Invariant F: *the durable store must refuse any append
  whose epoch is lower than the highest it has durably accepted for that shard.*
  Ships `FencingMode::Shadow` (count + log, **write still succeeds**);
  `Enforce` is owner-gated.
- ⭐ `fencing.rs` deviates from its own spec §4.1 deliberately: the epoch lives
  in a **per-shard fencing marker**, *not* the frame header, because
  `FRAME_HEADER_LEN` is a fixed 12 bytes shared byte-identically with
  `durable_eventlog.rs`. **This is the single most valuable fact in this
  document** — it means the epoch space can be widened (§3.2) with no on-disk
  format break.
- ⚠ **The Kubernetes `LeaseStore` adapter does not exist.**
  `grep -l 'kube\|k8s-openapi'` over `Cargo.toml` + `crates/*/Cargo.toml`
  returns nothing. **VERIFIED.**

### 1.5 Sharding / ownership

`affinity.rs:1-60` **VERIFIED**: `shard_for_i64` = `XxHash64` seed `0` over the
8 LE bytes of the `i64` execution id `% shard_count`, byte-identical to
`noetl-worker` `src/sharding.rs` and `noetl-server` `sharding::shard_for`, and
to `ehdb-l0/src/dataset.rs:149`. Ownership semantics:

- a write on a **non-owner is refused with no side effect** (no bytes, no
  sequence consumed) — safe to re-route;
- a read on a non-owner **cold-loads the durable segments read-only**.

⭐ That second line is already the mechanism a follower read needs (§4.3).

### 1.6 Ordering

Two independent ordering facilities, and neither is a global clock:

1. **Snowflake ids** (`server/src/snowflake.rs`) — 41-bit ms since the NoETL
   epoch `2024-01-01Z` | 10-bit machine id (`NOETL_SERVER_MACHINE_ID`, max 1023)
   | 12-bit per-ms sequence. **VERIFIED.** Orderable across machines *only to the
   precision of each machine's wall clock*; there is **no uncertainty bound**
   anywhere and no clock-offset check.
2. **L0 `global_sequence`** — a monotone counter held **per engine**, assigned
   inside the append (`engine.rs:732 let seq = self.global_sequence + 1`) and
   recovered as `manifest.max_sequence()` (`engine.rs:405`, `:483`).
   **VERIFIED.** It is gapless and ascending *because a single writer serialises
   appends* (`engine.rs:712` comment). It is **not** globally coordinated: a
   second engine in a second region would mint the same integers.

### 1.7 Membership

- `ehdb-gossip` (599 LOC across 4 files) adopts **foca v2** for SWIM transport
  and failure detection; every transition is appended to D8. Status in its own
  `lib.rs`: **INERT** — no socket, no runtime, no bring-up; `GossipOrigin` is
  deliberately unconstructible without a verifier. **VERIFIED.**
- **D8 `RuntimeDataset`** (`ehdb-l0/src/runtime.rs`, 742) — register /
  heartbeat / deregister / `list_live_since(min_heartbeat)`, liveness as a
  **wall-clock-free predicate** over a monotone per-worker counter.
  `docs/rfc/ehdb-topology-membership.md` §0 records **0 consumers and 0 tests**
  across server + worker + gateway. **VERIFIED** (that RFC's own measurement;
  I did not re-run the consumer count).

### 1.8 What does NOT exist — with the denominator

Searched **129 `.rs` files under `ehdb/crates/`**, case-insensitive, with
`grep -ril <term> crates --include='*.rs'`:

| Term | Hits | Reading |
| :-- | --: | :-- |
| `hlc`, `hybrid logical` | **0** | no hybrid logical clock |
| `truetime`, `external consist` | **0** | no clock-uncertainty concept |
| `commit_ts` | **0** | no commit timestamp |
| `leaseholder`, `follower_read` | **0** | no leaseholder/follower-read vocabulary |
| `raft` | 11, **all prose** (`election.rs:23-26`, `lib.rs:85`, `catalog.rs:32`, test docs) | explicitly *not* built, by decision |
| `region` | 7 files, **all key-string or test fixtures** | see below |
| `locality` | **1** — `affinity.rs`, in a doc comment | not a type |
| `zone` | 3 — `failure_domain.rs` prose, `storage`, `transaction` | not a placement axis |
| `survival` | 3 — prose only | no survival goal |
| `tenant` | 8 files | `NOETL_EHDB_TENANT` exists as a namespace string |

⚠ **The `region` hits are the one that could mislead.** `region` appears as a
**segment of the KV / object logical-key string**:
`noetl/env=…/region=us-central1/cell=…/shard=s0042/tenant=…/execution=…`
(`object.rs:11`, `:1209`, `:1491`; `kv.rs:1770`; `vector.rs:1643`;
`bin/ehdb-local-reference.rs:1030-1110`). **VERIFIED.** It is a **naming
convention inside an opaque key**, not a typed coordinate: nothing routes on it,
nothing places on it, nothing validates it. Treating it as existing multi-region
support would be the exact class of error this program keeps making.

### 1.9 The compat precedent that makes additive fields safe

**VERIFIED**, and it is the template every new field below follows —
`ehdb-l0/src/dataset.rs:154-199`:

> ⚠ `deny_unknown_fields` was REMOVED here deliberately, and removing it is a
> migration step in its own right. Records persist as `serde_json` frames on
> disk (`part.rs:277`). With `deny_unknown_fields`, a binary that predates a new
> field **errors** when it reads a record carrying it — so adding any column
> would make a rollback unable to read what the newer binary wrote, on a tier
> that serves `primary`. Tolerating unknown fields must therefore ship and be
> deployed BEFORE anything writes one.

and, on `event_id`:

> ⚠ Why `Option` + `skip_serializing_if`: a record with no `event_id` serialises
> **byte-identically to today**, so a rollback can still read everything written
> while the producer has not been switched on.

The same note guards the cross-process `EventLogAppendOutcome`
(`ehdb-reference/src/eventlog.rs:142`). **151 `deny_unknown_fields` sites remain
across the crates** — so this is a per-struct property, not a workspace-wide
posture, and each struct a new field touches must be checked individually.

---

## 2. The three constraints that shape the whole design

**C1 — EHDB has no consensus and will not grow one for storage.**
`lib.rs:85` makes the immutable-part/N-way-copy choice explicit and retires
per-shard Raft. Immutable objects never conflict, so copy needs no agreement.
Therefore: **do not port Cockroach's Raft ranges.** Port its *placement*,
*leaseholder*, *MVCC read* and *survival-goal* concepts, which are separable
from its replication mechanism.

**C2 — ordering is leaderful per shard, and that is load-bearing.**
Gaplessness and ascending order hold *because* one writer serialises
(`engine.rs:712`). Anything that admits a second concurrent writer to a shard —
including a second region — breaks the sort-key contract that part pruning,
cursors and the claim path all rest on. Therefore: **one writer per shard,
globally, at any instant.** Multi-region changes *where* that writer is, never
*how many* there are.

**C3 — the durable format is effectively frozen at the frame header, and thawed
above it.** `FRAME_HEADER_LEN` is 12 bytes shared byte-identically with
`durable_eventlog.rs`; widening it makes every existing segment unreadable
(`fencing.rs` deviation note). But the record body is `serde_json` with the
expand-first precedent of §1.9. Therefore: **every new field goes in the record
body as `Option<T>` + `skip_serializing_if`, or in an out-of-band per-shard
marker — never in the frame header.**

Everything in §3–§6 is the consequence of these three.

---

## 3. Concept → EHDB-primitive mapping

`REUSE` = the primitive exists and is extended additively.
`NEW` = genuinely new code.
`DECLINE` = deliberately not built, with the reason.

### 3.1 Spanner

| Spanner concept | EHDB primitive | Verdict | Notes |
| :-- | :-- | :-- | :-- |
| **TrueTime** (GPS/atomic, hardware ε) | — | **DECLINE** | No TrueTime hardware, and no credible path to one on GKE Autopilot. |
| **Clock substrate** | `HlcClock` beside `SnowflakeGenerator` (`server/src/snowflake.rs`) | **NEW (small)** | 48-bit physical ms ‖ 16-bit logical. Recommended substrate — see fork F1. |
| **Commit timestamp** | `EventRecord.commit_hlc: Option<u64>` (`dataset.rs:164`) | **NEW field, REUSE carrier** | Additive per §1.9. **Never** replaces `global_sequence`, which stays the sort key. |
| **External consistency** | HLC + uncertainty interval + **fail-closed max-offset halt** | **NEW** | Achieved by *restart-on-uncertainty* (Cockroach's method), not commit-wait — see F1. The halt needs a peer set, which is why D8/gossip is a prerequisite. |
| **Commit-wait** | opt-in `NOETL_EHDB_COMMIT_WAIT_MS` | **NEW, default 0 (off)** | Only meaningful with a *trusted* ε. Offered as a knob, recommended off. |
| **Bounded-staleness read** | closed timestamp derived from `UnreplicatedTracker` + sealed-part watermark | **REUSE** ⭐ | `unreplicated.rs` already computes *"age of the oldest acked-but-not-yet-durable record"* — the exact quantity a closed timestamp needs. |
| **Exact-staleness read** | read at HLC `ts`; parts pruned by `[min,max]` sort key via `catalog.rs` | **REUSE + NEW predicate** | Pruning machinery exists; the ts→sequence resolution is new. |
| **Placement / leader-region policy** | `Locality` on `ReplicaTarget` (`engine.rs:230`) + lease holder attribute | **REUSE + NEW field** | |
| **Survival goal (zone / region)** | `L0Config::require_distinct_domains: bool` (`engine.rs:111`) → `SurvivalGoal` | **REUSE, widened** | Today's `true` maps exactly to `SurvivalGoal::Zone`. |
| **Paxos groups per split** | — | **DECLINE** | C1. |
| **Read-only / read-write txns** | — | **DECLINE** | See §3.2 distributed txns. |

### 3.2 CockroachDB

| Cockroach concept | EHDB primitive | Verdict | Notes |
| :-- | :-- | :-- | :-- |
| **Range** (a key span) | **Shard** — `shard_for_i64` XxHash64 seed 0 % `shard_count` (`affinity.rs`) | **REUSE** | Fixed hash partition, not a splittable span. No rebalancer, no split/merge — and none is planned. |
| **Leaseholder** | The shard's elected writer (`election.rs` `LeaseRecord.holder`) | **REUSE** ⭐ | Already exists with the right semantics; it is just not authoritative yet. |
| **Lease epoch / fencing token** | `LeaseRecord.transitions` + the per-shard fencing marker (`fencing.rs`) | **REUSE** ⭐ | And, per C3, the marker is out-of-band so its payload can grow. |
| **Raft replication of the log** | — | **DECLINE** | C1. Replaced by: immutable-part N-way copy + cold-load + fungible writer. |
| **Zone configs** | `FailureDomain` + `validate_replica_domains` + `require_distinct_domains` | **REUSE, widened** | |
| **Locality-aware placement** | `Locality { region, zone, domain }` on `ReplicaTarget` | **NEW field over REUSE** | `FailureDomain::Remote{provider,bucket}` already models an off-node domain. |
| **Follower reads** | non-owner read already **cold-loads read-only** (`affinity.rs`) | **REUSE** ⭐ | Needs only a closed-timestamp gate to become a *correct* follower read. |
| **MVCC** | — | **DECLINE, and note why it is not needed** | D1 is an append-only log: history is intrinsic. "Read at ts" = "read the prefix ≤ ts", not a version chain. Derived tiers (D3/D4) get snapshot semantics from *re-folding the log at ts*, which is already how D3 works. |
| **Distributed txns / 2PC over consensus** | — | **DECLINE** | The write unit is a single-shard append; there is no multi-shard atomic requirement in the D1–D10 set. Building 2PC would be exactly the "reinvent a subtle algorithm that fails silently" case [`self-sufficiency.md`](../../../../agents/rules/self-sufficiency.md) forbids. **If** a cross-execution atomic requirement ever appears, it is a new RFC, not a phase here. |
| **Closed timestamps** | derived from seal watermark + `UnreplicatedTracker` | **REUSE** | |
| **Survivability (ZONE vs REGION)** | `SurvivalGoal` | **NEW enum over REUSE** | ⚠ Asymmetric — see §3.3. |
| **Node liveness / gossip** | D8 `RuntimeDataset` + `ehdb-gossip` (foca) | **REUSE, both inert** | Adoption plan, not construction. |

### 3.3 Cross-regional — and the one honest asymmetry

| Cross-region concern | Design | Verdict |
| :-- | :-- | :-- |
| **Per-region event-log replica** | A region is an extra `ReplicaTarget` with `FailureDomain::Remote` and a `Locality`. Sealed parts copy there; the manifest records it. | **REUSE** |
| **Coherent global order** | **Leaderful per shard** (C2) + HLC for cross-shard comparison. `global_sequence` stays a *per-shard* order; it is never a global one and must stop being read as one. | **REUSE + NEW** |
| **Read-locality routing** | A `RoutePlan` picks the nearest replica whose closed timestamp satisfies the request's `VisibilityPlan`. | **NEW resolver, REUSE transport** |
| **Cross-region replication of D3/D4/D5** | ⭐ **Do not replicate them. Re-derive them per region from the replicated D1 log.** Projections are deterministic folds; shipping the log is cheaper than maintaining a second consistency contract, and the existing cross-store parity comparator becomes the cross-region equality oracle for free. | **REUSE** |
| **Per-shard epoch → multi-region leadership** | The epoch stays a monotone `u64`; the **region is an attribute of the holder, not of the epoch**. Widening the epoch into a tuple would need a total order across regions, which is the thing there is no coordinator for. | **REUSE** |

⚠⚠ **The asymmetry, stated up front because it decides the phase order:**

> **Region-survivable *reads* are reachable long before region-survivable
> *writes*.**

Reads need only a replica + a closed timestamp — both in-repo primitives.
Writes need a **lease authority that survives losing a region**, and today the
only CAS EHDB trusts is a single Kubernetes API server (`election.rs:23`), which
is per-cluster. That is fork **F2b**, it is genuinely open, and it is the last
phase. Anyone who reads "multi-region" as "writes fail over automatically" will
be wrong for most of this plan's life, so every phase states which half it buys.

---

## 4. The dimensional model — six axes, three resolvers

"Omni / multi-dimensional" is only affordable if the axes **compose in data**
rather than multiplying in code. The rule this plan holds to:

> ⛔ **No axis may introduce a branch inside a tier driver.**
> The number of code paths stays equal to the number of tiers, forever.

### 4.1 The axes

| # | Axis | Values | Bound at | Who consumes it |
| :-- | :-- | :-- | :-- | :-- |
| A1 | **Region** | `us-central1`, … | engine open (placement) + per request (routing) | Placement, Route |
| A2 | **Tier / dataset** | D1…D10 | compile time | — (already fixed; `dataset.rs`) |
| A3 | **Shard** | `shard_for(execution_id)` | per record | Placement, Route |
| A4 | **Consistency level** | `strong` \| `bounded(d)` \| `exact(ts)` | per read request | Visibility |
| A5 | **Staleness bound** | duration or ts | per read request | Visibility |
| A6 | **Survival goal** | `zone` \| `region` | engine open | Placement |

A2 is already fixed and compiled in (RFC §0.1's "adding a dataset is a
deliberate, compiled-in change, never runtime DDL"). A3 already exists. So the
genuinely new axes are **A1, A4, A5, A6** — four, not six.

### 4.2 The three resolvers

Each axis feeds exactly one resolver, and each resolver produces a **plain data
plan** that the existing drivers consume. Drivers never read an axis.

```
                A1 region ─┐
                A6 goal   ─┼──► PlacementResolver ──► PlacementPlan   (engine OPEN time)
                A3 shard  ─┘                          { replicas: Vec<ReplicaTarget+Locality>,
                                                        min_distinct: SurvivalGoal }

                A1 region ─┐
                A3 shard  ─┼──► RouteResolver     ──► RoutePlan       (per REQUEST)
                A4 level  ─┘                          { target: Owner | Replica(id),
                                                        may_follower_read: bool }

                A4 level  ─┐
                A5 bound  ─┴──► VisibilityResolver ─► VisibilityPlan  (per READ)
                                                      { floor_hlc: Option<u64>,
                                                        require_closed_ts: Option<u64> }
```

**Why this does not explode.** `4 axes × 6 tiers` would be 24 code paths if each
tier branched. Instead there are `3` resolvers + `6` unchanged drivers = 9 units,
and the resolvers are pure functions over config and a request descriptor —
which makes them exhaustively table-testable without a cluster.

### 4.3 The identity property — how "no phase breaks an existing feature" is *proved*, not asserted

Under today's configuration —
`region = {the one region}`, `survival = zone`, `consistency = strong`,
`staleness = none` — each resolver must return **exactly today's behaviour**:

| Resolver | Degenerate output | Equals today because |
| :-- | :-- | :-- |
| `PlacementPlan` | `replicas = [replica-0]`, `min_distinct = Zone` | `engine.rs:300 open()` already constructs `vec![ReplicaTarget::new("replica-0", …)]`, and `require_distinct_domains` is *"only consulted for a set of two or more replicas"* (`engine.rs:108`) |
| `RoutePlan` | `target = Owner`, `may_follower_read = false` | `affinity.rs` ownership, unchanged |
| `VisibilityPlan` | `floor_hlc = None`, `require_closed_ts = None` | no gate, i.e. today's read |

**M0's exit criterion is that identity, demonstrated by a mutation battery**
(§5), not by a passing test suite. The program's history is unambiguous here:
four separate guards have been found enforcing the class they were written to
prevent, most recently the `result_store, false` assertion that **pinned the
`keep_refs` bug** (TRACE-RESULTS.md). A green suite is not evidence; a suite
that goes red when the resolver is mutated is.

### 4.4 Where a region label lives

**Not** in the logical key string. §1.8 found `region=` already inside KV /
object keys, and the temptation is to route on it. Do not: those keys are
opaque, content-addressed through a SHA-256 subject (`object.rs:40-56`), and
nothing parses them. Region belongs in:

1. `Locality` on `ReplicaTarget` — placement, and
2. `ReplicaLocation` in the manifest — where a copy actually landed, and
3. `LeaseRecord.holder`'s identity string — who leads, and
4. D8 `RuntimeOp.contract` — which is *already a free-form descriptor field*
   (`runtime.rs:53`) and needs no schema change to carry it.

The existing key strings stay exactly as they are.

---

## 5. Phased rollout

Each phase names: the gating flag, entry criteria, exit criteria, blast radius,
and rollback. **Every phase is independently shippable and independently
reversible.** Ordering rule: *nothing that can refuse or move a write appears
before M5.*

House discipline applied to all phases, from
[`deployment-validation.md`](../../../../agents/rules/deployment-validation.md),
[`representation-drift.md`](../../../../agents/rules/representation-drift.md)
and this program's own scar tissue:

- kind before prod, always;
- default `off`/`shadow`, promotion owner-gated;
- **every new metric pins its known label values at 0 unconditionally** — never
  inside a config branch (the server#315 mistake);
- **every proof publishes its denominator** — the population measured and the
  idioms covered;
- **every proof states which function it measures**, and verifies that function
  is on the path being changed (the `compare_sources` lesson: v3.108.2 shipped a
  correct hydration fix and the instrument moved by 0 of 40);
- a positive control that fails on first run is doing its job.

### M0 — Resolvers as identity functions

| | |
| :-- | :-- |
| **Flag** | none (the resolvers exist and are pure) |
| **Entry** | nothing |
| **Exit** | (a) `PlacementPlan`/`RoutePlan`/`VisibilityPlan` exist and are constructed on every path; (b) under default config the produced plans are byte-equal to today's hard-coded values; (c) a **mutation battery on a green baseline**: mutating each resolver's default arm turns a test red — with a positive control proving the battery can fail; (d) no change to any on-disk byte |
| **Blast radius** | compile-time only; no behaviour |
| **Rollback** | revert |
| **Why first** | Every later phase is "give a resolver a non-default input". If the identity is not proven here, no later phase's rollback is trustworthy. |

### M1 — Locality metadata, enforced nowhere

| | |
| :-- | :-- |
| **Flag** | `NOETL_EHDB_LOCALITY` (e.g. `region=us-central1,zone=us-central1-a`), default unset |
| **Entry** | M0 exit |
| **Exit** | (a) `Locality` recorded on `ReplicaTarget` and in `ReplicaLocation`; (b) unset ⇒ `FailureDomain::Undeclared`-equivalent, which **already fails closed** (`failure_domain.rs`) — a locality-less replica can never be *shown* independent; (c) `require_distinct_domains` behaviour bit-identical; (d) manifests written with locality are read by a **rollback binary** without error (the §1.9 expand-first check, run explicitly) |
| **Blast radius** | manifest bytes grow by a small optional field; nothing reads it |
| **Rollback** | unset the flag; the field is `Option` + `skip_serializing_if`, so new manifests serialise byte-identically again |

### M2 — HLC clock substrate, SHADOW

| | |
| :-- | :-- |
| **Flag** | `NOETL_EHDB_HLC` = `off` \| `shadow` \| `on`, default `off` |
| **Entry** | M1 exit; D8 has ≥1 real consumer (see M2a) |
| **Exit** | (a) `EventRecord.commit_hlc: Option<u64>` stamped on 100 % of new appends under `shadow`; (b) **nothing reads it** — proven by mutating the stamp to a constant and seeing no behavioural test change; (c) a rollback binary reads the new records (expand-first, §1.9 — and the tolerate-unknown release must be **deployed everywhere before** the stamping release, not merely merged); (d) `ehdb_clock_offset_millis` gauge live, **pinned at 0** so absence is distinguishable from health; (e) HLC monotonicity survives a process restart and a backwards wall-clock step, under test |
| **Blast radius** | 8 extra bytes per record; `global_sequence` untouched and still the sort key |
| **Rollback** | flag → `off`; records already written keep an unread field |
| ⚠ | The `deny_unknown_fields` audit is **per struct** — 151 sites remain. Enumerate the structs on the path and check each; do not generalise from `EventRecord`. |

**M2a — D8 / gossip adoption (prerequisite, may run in parallel with M1).**
D8 has 0 consumers and 0 tests. The max-offset halt in M2 needs a peer set, and
the region-aware routing in M6 needs a membership view. Exit: D8 exercised by a
real consumer with tests, `ehdb-gossip` bound to a socket in kind only, still
inert in prod. ⚠ *"Does it exist" and "does it work" are independent questions*
— D8 must be exercised before it is trusted.

### M3 — Closed timestamp + bounded-staleness reads

| | |
| :-- | :-- |
| **Flag** | `NOETL_EHDB_READ_CONSISTENCY` = `strong` \| `bounded` \| `exact`, default `strong` |
| **Entry** | M2 exit (`shadow`, i.e. every record carries an HLC) |
| **Exit** | (a) a per-shard closed timestamp published as a gauge, derived from the sealed-part watermark and `UnreplicatedTracker::snapshot` — with the derivation's **denominator printed**; (b) a bounded-staleness read over a **fixed population** returns a result set that is a prefix of the strong read's, ≥ N executions, with a **numeric prediction made before the run**; (c) a request asking for a staleness the closed timestamp cannot satisfy is **refused**, not silently served stale |
| **Blast radius** | read-only; default `strong` changes nothing |
| **Rollback** | flag → `strong` |
| ⚠ | **Do not build this proof on the cross-store parity comparator or the `projection-fold/diff` endpoint.** Both have known asymmetries: `digest_mismatch` is an open snapshot-writer-vs-verifier defect (TRACE-RESULTS.md), and the diff endpoint *"is not on the serve path"*. Instrument the read path itself. |

### M4 — Survival-goal placement

| | |
| :-- | :-- |
| **Flag** | `NOETL_EHDB_SURVIVAL_GOAL` = `zone` \| `region`, default `zone` |
| **Entry** | M1 exit + at least one genuinely remote substrate implementing `DurableSubstrate` with `FailureDomain::Remote` |
| **Exit** | (a) `zone` is behaviourally identical to today's `require_distinct_domains: true`; (b) under `region`, `validate_replica_domains` **refuses** a replica set whose members share a region — proven by a test that *fails* when the check is removed; (c) a sealed part remains readable after one domain is made unreachable (kind: unmount / deny the path), with a negative control showing the test can detect the absence; (d) `ehdb_replica_placement_violations_total{goal}` pinned at 0 for both label values |
| **Blast radius** | engine **open** can now refuse to start on a misconfigured replica set. This is the first phase that can fail a deploy — deliberately placed after the read-side phases and before anything touching writes |
| **Rollback** | flag → `zone` |
| ⚠ | The single most valuable finding in `failure_domain.rs` is that prod's "replication" writes to a **subdirectory of the same PVC** — *"an RF of N over one domain is an RF of 1 wearing a larger number"*. M4 is the phase that makes that observable, and it should be **run in shadow first** (report violations, refuse nothing) for exactly that reason. |

### M5 — Fencing `Enforce` + a real `LeaseStore` — **the gate**

| | |
| :-- | :-- |
| **Flag** | `NOETL_EHDB_FENCING` = `shadow` \| `enforce`, default `shadow` (already exists) |
| **Entry** | M0–M4 exit |
| **Exit** | (a) a Kubernetes `LeaseStore` adapter exists (the `kube` / `k8s-openapi` dependency the owner approved), with RBAC on `coordination.k8s.io/leases`; (b) election is **authoritative** — exclusion no longer rests on `replicas: 1`; (c) `enforce` promoted, and a deliberately stale-epoch write is **refused** in kind with the `stale_epoch` prefix in logs; (d) `ehdb_fencing_refused_total{mode}` pinned at 0 for both modes |
| **Blast radius** | ⚠⚠ **highest in the plan.** This is the first thing that can refuse a production write. It is also the prerequisite for every remaining phase — nothing multi-region is safe while single-writer is an orchestration preference |
| **Rollback** | flag → `shadow`; the store counts and logs, writes succeed |
| **Note** | This is the existing "stage 2" from `FENCING-SUBSTRATE-BUILD-HANDOVER.md`, unchanged. This plan does not re-scope it; it explains why everything below waits for it. |

### M6 — Read-locality routing / follower reads

| | |
| :-- | :-- |
| **Flag** | `NOETL_EHDB_READ_LOCALITY` = `owner` \| `nearest`, default `owner` |
| **Entry** | M3 + M5 exit; M2a (membership) live |
| **Exit** | (a) under `nearest`, a read is served by a non-owner replica **only when** its closed timestamp satisfies the `VisibilityPlan`; (b) a follower read and a strong read over a fixed population return identical results modulo the declared staleness — denominator published; (c) `ehdb_read_served_total{locality}` pinned at 0 for every value; (d) when no replica qualifies, the read **falls back to the owner**, and that fallback is counted |
| **Blast radius** | read path only; `owner` is today |
| **Rollback** | flag → `owner` |
| **Reuse** | `affinity.rs`'s *"a read on a non-owner cold-loads the durable segments read-only"* is already the mechanism; M6 adds only the freshness gate |

### M7 — Cross-region log replication + per-region re-derivation

| | |
| :-- | :-- |
| **Flag** | `NOETL_EHDB_REPLICA_TARGETS` (declarative list with localities), default single-entry |
| **Entry** | M4 + M6 exit |
| **Exit** | (a) sealed D1 parts land in a second region's substrate; (b) a second-region reader **cold-loads** and reproduces the exact record set + `global_sequence` (the fungible-writer property, `engine.rs:436`); (c) D3/D4/D5 in region B are **re-derived from the replicated log**, not shipped — and the derived state matches region A's over a fixed population; (d) the replication lag is a gauge with a published as-of, per [`representation-drift.md`](../../../../agents/rules/representation-drift.md)'s "a number with no staleness signal is not evidence" |
| **Blast radius** | more bytes copied; region A's write path unchanged — the uploader is already asynchronous and *"a slow substrate never blocks the append hot path"* (`substrate.rs`) |
| **Rollback** | drop the extra replica target; the manifest's `replicas` list shrinks |
| ⚠ | Region B is **read-only** after M7. It cannot take writes. That is M8. |

### M8 — Region-survivable writes — **owner-gated, fork F2b must be resolved first**

| | |
| :-- | :-- |
| **Flag** | `NOETL_EHDB_WRITE_FAILOVER` = `off` \| `manual` \| `auto`, default `off` |
| **Entry** | M7 exit **and** a written decision on F2b (lease authority) |
| **Exit** | (a) shard leadership can move to region B; (b) the epoch advances monotonically **across** the move — the new holder's `transitions` strictly exceeds the old; (c) the old holder's writes are **refused** by Invariant F (this is the payoff of M5); (d) a manual failover is exercised in kind with a measured write-unavailability window |
| **Blast radius** | ⚠⚠ maximal. Moves the single writer. |
| **Rollback** | flag → `off`; leadership stays where it is |
| **Recommendation** | Ship `manual` and stop. `auto` requires trusting a failure detector to decide a region is gone, and a wrong decision here is a split-brain on the tier that is `primary`. `manual` gets the availability benefit with a human in the loop. |

### Phase dependency

```
M0 ─► M1 ─┬─► M2 (needs M2a) ─► M3 ─┐
          └─► M4 ──────────────────┬┴─► M5 ─┬─► M6 ─► M7 ─► M8
 M2a ─────────────────────────────┘         └─ (M5 gates everything right of it)
```

---

## 6. Feature-flag / plug matrix

| Flag | Default | Enables | Proven by | Blast radius | Rollback |
| :-- | :-- | :-- | :-- | :-- | :-- |
| *(none — M0)* | — | resolver identity | mutation battery, green baseline + positive control | none | revert |
| `NOETL_EHDB_LOCALITY` | unset | region/zone recorded on replicas | manifest diff; rollback-binary read | manifest bytes | unset |
| `NOETL_EHDB_HLC` | `off` | `off`\|`shadow`\|`on` — commit-HLC stamping | 100 % stamped; mutate-to-constant shows nothing reads it; offset gauge pinned 0 | +8 B/record | `off` |
| `NOETL_EHDB_COMMIT_WAIT_MS` | `0` | Spanner-style commit-wait | latency histogram; **recommended to stay 0** | write latency | `0` |
| `NOETL_EHDB_READ_CONSISTENCY` | `strong` | `strong`\|`bounded`\|`exact` | prefix property on a fixed population, numeric prediction first | read path | `strong` |
| `NOETL_EHDB_SURVIVAL_GOAL` | `zone` | `zone`\|`region` placement refusal | refusal test that fails when the check is removed; domain-unreachable read test with a negative control | **engine open can fail** | `zone` |
| `NOETL_EHDB_FENCING` | `shadow` | `shadow`\|`enforce` — Invariant F | stale-epoch write refused in kind, `stale_epoch` in logs | ⚠⚠ **can refuse prod writes** | `shadow` |
| `NOETL_EHDB_READ_LOCALITY` | `owner` | `owner`\|`nearest` follower reads | follower vs strong equality modulo staleness, denominator published | read path | `owner` |
| `NOETL_EHDB_REPLICA_TARGETS` | 1 entry | N-way cross-region part copy | cold-load in region B reproduces record set + sequence | bytes copied | drop targets |
| `NOETL_EHDB_WRITE_FAILOVER` | `off` | `off`\|`manual`\|`auto` | epoch monotone across the move; old holder refused | ⚠⚠ moves the writer | `off` |
| `NOETL_EHDB_SEAL_MAX_AGE_MS` | `5000` (prod, manifest) | bounds the unsealed RF=1 tail | already armed; **this plan changes nothing about it** | existing | existing |

**Pre-existing flags this plan deliberately does not touch:**
`NOETL_EHDB_EVENTLOG_BACKEND` (inert on prod's `Service` branch — §1.2),
`NOETL_EHDB_TIER_QUERY_SOURCE`, `NOETL_EHDB_EVENTLOG`,
`NOETL_PROJECTOR_ENABLED` / `NOETL_PROJECTOR_OWNS_SNAPSHOT` (stage 1, blocked on
the `digest_mismatch` defect — an independent track).

---

## 7. Open design forks

Recommendations are stated so nothing blocks. Each is revisitable without
unwinding earlier phases.

### F1 — Clock substrate: HLC vs global sequencer vs commit-wait

| Option | Pro | Con |
| :-- | :-- | :-- |
| **A. HLC** (48-bit physical ‖ 16-bit logical) | No coordination; degrades to a Lamport clock under skew; the standard choice absent TrueTime; small and testable | Ordering is causal + approximate-real-time, not externally consistent without an uncertainty protocol |
| **B. Global sequencer** | A true total order | A single global coordinator is a cross-region round trip on the write path **and** exactly the external-service dependency [`self-sufficiency.md`](../../../../agents/rules/self-sufficiency.md) forbids |
| **C. Commit-wait on NTP ε** | Genuine external consistency | Only as sound as ε; an unmeasured ε buys a false guarantee — worse than none |

⭐ **Recommended: A, with C available as an off-by-default knob.**
External consistency is approached the way Cockroach does it — an *uncertainty
interval* plus a **fail-closed max-offset halt**, not a wait. Two commitments
that make it honest rather than decorative:

1. ε is **configured and observed**, with `ehdb_clock_offset_millis` pinned at 0.
   A clock guarantee whose offset is unmeasured is a representation with nothing
   forcing it to agree with reality.
2. A node detecting offset > ε/2 against its D8/gossip peer set **halts**. This
   is why M2a is a prerequisite: without a peer set the halt cannot fire, and an
   unfirable safety check is the exact defect class this program keeps finding.

⚠ Do **not** reuse the snowflake timestamp as the HLC. It is 41-bit ms with no
logical component and no uncertainty bound; conflating them would silently
weaken both.

### F2a — Leadership: leaderful per shard vs Raft ranges

⭐ **Recommended: leaderful per shard.** Not a close call — C1 and C2 decide it,
`election.rs:23` already argues it, and `election.rs` + `fencing.rs` already
implement the mechanism. Raft ranges would mean re-deriving replication for a
store whose parts are immutable and therefore conflict-free. **Closed.**

### F2b — Lease authority under region failure — **genuinely open**

The k8s Lease CAS is per-cluster. Losing the region hosting that API server
means no writer can be elected anywhere.

| Option | Pro | Con |
| :-- | :-- | :-- |
| **A. One home cluster's API server is the lease authority** | Zero new machinery; works today | That cluster is a cross-region dependency; losing it blocks write failover — i.e. reads survive a region, writes do not |
| **B. Leases in EHDB over a D4-KV CAS** | Self-sufficient, no external service | Needs consensus EHDB does not have and will not build (C1). A CAS with no agreement underneath is not a CAS |
| **C. An embedded consensus library scoped to leases only** (e.g. Raft over *just the lease record*, ~KB of state) | Genuinely region-survivable; the "proven library, not hand-rolled" shape `self-sufficiency.md` prescribes; small, bounded state | A new dependency and a new operational surface; only justifiable once M7 is real |

⭐ **Recommended: A now, C later, never B.** Take A through M7 and **state
plainly in every artefact that the survival goal for writes is ZONE while reads
reach REGION.** Re-open C as its own RFC when M8 is actually wanted. The framing
recorded for the unsealed-tail gap applies here too: name the *specific* window
that is not covered, rather than making a general claim of resilience.

### F3 — Derived-tier cross-region strategy: replicate vs re-derive

⭐ **Recommended: re-derive.** D3/D4/D5 are deterministic folds of D1
(`projection.rs`), the log is already being replicated for durability, and
re-deriving avoids a second consistency contract, a second lag metric and a
second divergence class. The cross-store parity comparator becomes the
cross-region equality oracle at no extra cost.
⚠ With the standing caveat that the comparator has a **known open asymmetry**
(`digest_mismatch`, and `fold()` omitting `normalise_null_json` while
`fold_with_body()` calls it). Fix those on the stage-1 track before leaning on
the comparator as a cross-region oracle, or the oracle will report a divergence
that is its own.

### F4 — Shard model: fixed hash vs splittable ranges

⭐ **Recommended: keep the fixed hash.** `shard_for_i64` is byte-identical
across four call sites (server, worker, ehdb-reference, ehdb-l0). Splittable
ranges would need a rebalancer, a split/merge protocol, and a routing directory
— three subtle distributed algorithms, for a partition function that is not
currently a bottleneck. Revisit only with a measured hot-shard problem,
denominator published.

### F5 — MVCC

⭐ **Recommended: none.** An append-only log has history intrinsically; "read at
ts" is "read the prefix ≤ ts". Adding version chains would duplicate the log's
own guarantee — and denormalised state that is also derivable is precisely the
shape that produced the frozen `noetl.execution.status` column
([#235](https://github.com/noetl/ai-meta/issues/235)).

---

## 8. What this plan deliberately does not do

- **No Raft, no Paxos, no 2PC, no distributed transactions.** C1, and the
  no-multi-shard-atomicity reading of the D1–D10 set.
- **No general-purpose database features.** The layered-platform RFC's program
  invariant binds every layer: no arbitrary schemas, no DDL, no cost-based
  planner. Multi-region does not relax it.
- **No change to `FRAME_HEADER_LEN`, and no segment-key migration.** C3.
- **No business data crosses a region.** EHDB holds control-plane data plus a
  bounded, evictable processing cache; the customer's store remains the system
  of record.
- **No new external service.** Every option above that would add one is declined
  or deferred to its own RFC.
- **No re-scoping of the in-flight tracks.** Stage 1 (projector /
  `digest_mismatch`) and stage 2 (fencing) are unchanged; this plan consumes
  stage 2 as M5 and states why it is the gate.

---

## 9. Failure modes this plan is specifically defended against

Drawn from this program's own record, because these are the ways the work
actually goes wrong here:

| Failure class | Where it bit before | Defence in this plan |
| :-- | :-- | :-- |
| **A guard enforcing the bug** | the `result_store, false` assertion pinned the `keep_refs` defect; four such guards to date | M0's mutation battery with a green baseline and a positive control; every phase's exit names a mutation that must turn it red |
| **Absent ≠ zero** | the prod gateway served a 0-byte `/metrics`; pinned reasons placed inside a config branch (server#315) | every new metric pins its known label values at 0 **unconditionally** |
| **A wrong denominator** | `spec-env-currency` measured 56 of 152 env vars; `knob-observability` reported 5 false positives of 6 | every exit criterion publishes the population and the idioms covered; §1.8 above does the same |
| **An instrument not on the path** | v3.108.2 shipped a correct fix and the metric moved by 0 of 40 | every proof names the function it measures and shows it is on the changed path; M3 explicitly forbids the fold-diff endpoint |
| **Existence read as reachability** | D8: implemented, 0 consumers, 0 tests. `ehdb-gossip`: inert. `NOETL_STATE_AFFINITY_ROUTE`: one reader, zero callers | M2a exists solely to make D8 *reached* before anything trusts it |
| **A representation acted on** | a dry-run proved one field and the whole object was applied — 55 min of prod dispatch down | nothing in this plan applies anything; when it ships, [`apply-safety.md`](../../../../agents/rules/apply-safety.md)'s full-object diff is the gate |
| **A stale memory/doc claim** | this document found one: `seal_max_age` "has no prod caller" is false (§1.3) | every claim carries VERIFIED / VERIFIED (manifest) / ASSUMED |

---

## 10. Summary for a reader with two minutes

1. EHDB is **already half of Cockroach's storage layer** — immutable parts,
   N-way replica sets, a manifest that is a replica-location catalog, failure
   domains that fail closed, cold-load, and a per-shard writer lease with a
   fencing epoch. What it lacks is **locality metadata, a clock, and a
   read-freshness gate**.
2. It will **never be Cockroach's consensus layer**, by an explicit decision
   recorded in `lib.rs:85`. So the port is of placement, leaseholder, MVCC-read
   and survival-goal concepts — not of Raft.
3. The clock should be **HLC**, not TrueTime and not a global sequencer, with
   external consistency approached via an uncertainty interval and a
   **fail-closed offset halt** that needs D8/gossip to exist first.
4. Multi-dimensionality is affordable because four new axes feed **three pure
   resolvers** producing data plans, and **no axis branches inside a tier
   driver**.
5. Phases M0–M4 cannot touch the write path at all. **M5 (fencing `Enforce`) is
   the gate**; everything genuinely cross-regional is behind it.
6. **Region-survivable reads land at M6/M7; region-survivable writes need fork
   F2b resolved and are M8.** Saying "multi-region" without that split is the
   overclaim this document exists to avoid.
