# EHDB packaging and integration — the library boundary

**Addendum to [`ehdb-embedded-state.md`](ehdb-embedded-state.md). Design only —
nothing built, nothing on prod.**

Decisions taken as given:

- EHDB is a **portable library crate** in its own repo, called **in-process** by
  the server (log + cache + projections), the worker (local append log) and
  eventually the gateway. Joining the repos means a **versioned crate
  dependency**, not a service.
- **In-process access is a direct call. No socket.** The only surviving
  transport is cross-shard / cross-component exchange **by key** — the
  `ExecutionAffinity` layer generalised. Local-first; transport only to reach
  someone else's shard.
- **KEDA retargets** from the writer's `:9102` onto the **server's own**
  `/metrics`, scaling server-with-embedded-EHDB as one unit.

Grounded in `ehdb@49fdefc`, `server@main`, `worker@main`, prod 2026-09-08.

---

## 1. Library boundary — it is already drawn, and it is clean

### The crate graph

```
ehdb-core  ──────────────────────────────────── (no deps; the root)
  ├── ehdb-l0          storage engine
  │     └── ehdb-feed          ← tokio, binds sockets (7 files)
  ├── ehdb-storage ─┬─ ehdb-catalog
  │                 ├── ehdb-system
  │                 └── ehdb-transaction ── ehdb-reference
  ├── ehdb-stream                                  └── ehdb-service ← tonic,
  └── ehdb-retrieval                                    arrow-flight, serves
```

### The decisive measurement

| | crates |
| :-- | --: |
| carry **no** network dependency at all | **9 of 11** |
| carry network deps | **2** — `ehdb-feed` (tokio, 7 files bind/serve), `ehdb-service` (tonic + arrow-flight, 1 file serves) |

`ehdb-l0` — the storage engine itself — has **zero** network dependencies.

> **There is no service wrapper to carve the engine out of.** The wrapper is two
> crates that sit *beside* the engine and depend on it, not around it. Embedding
> is a matter of **not depending on `ehdb-feed`/`ehdb-service`**, not of
> extraction.

That is a much better starting position than "retire the writer service"
implies, and it changes the shape of the work: the library boundary already
exists and is enforced by the dependency graph. What has to be built is the
*caller* side.

### ⚠ Two stacks, and they do not meet

`ehdb-reference` depends on `catalog / core / retrieval / storage / stream /
system / transaction` — and **not on `ehdb-l0`**. So the workspace holds two
lineages that never join:

| stack | crates | consumer today |
| :-- | :-- | :-- |
| **A — L0** | `ehdb-l0` + `ehdb-feed` | server's `command_bus` (as a network client) |
| **B — reference** | `ehdb-reference` + the transaction/catalog/stream layer + `ehdb-service` | worker (`flight_sql_endpoint`) |

### ⚠⚠ Two projection implementations, and the one in L0 has no consumers

| | consumers across server + worker + gateway |
| :-- | --: |
| `ehdb_l0::projection::ProjectionStore` | **0** |
| `ehdb_l0::projection::ExecutionProjection` | **0** |
| `ehdb_reference::LocalReferenceProjectionEngine` | live (worker Flight SQL) |
| `D1EventLog` / `PublishRouter` (the control) | 15 / 4 |

The control confirms the search idiom finds things. So `ehdb-l0`'s
`ProjectionStore` — with the `open` / `cold_load` / `record_state` / `get_state`
API the embedded RFC leaned on — **is currently dead code**, and the live
projection engine is in the other stack, with the `ProjectionCheckpoint` cursor
attached to *it*.

**This is the first packaging decision, and it is upstream of everything else:
which lineage becomes the embedded projection.**

- **Stack B (`ehdb-reference`)** is live, has the durable checkpoint, and is what
  the worker already runs. But it drags in `catalog`, `transaction`, `stream`,
  `system`, `retrieval` — a much larger surface than "an event log and a fold".
- **Stack A (`ehdb-l0`)** is the storage engine the RFC described, with the
  snapshot log and the `DurableSubstrate` seam — and it is the one nothing uses.

**Recommendation: stack A (`ehdb-l0`) as the embedded core, and treat stack B's
checkpoint as the design to port rather than the code to adopt.** Reasons: the
server needs an event log and a fold, not a transaction/catalog system; `l0` has
no network dependency and no transitive weight; and the RFC's snapshot/restore
story is `l0`'s. ⚠ The honest cost: `l0`'s projection path is **unexercised** —
zero consumers means zero production evidence, and its `ProjectionStore` should
be treated as untested code, not as a working component.

### The minimal embed API

Everything below already exists on `ehdb-l0` as a synchronous call:

| need | call |
| :-- | :-- |
| open | `L0Engine::open(config, Arc<dyn DurableSubstrate>)` |
| open for recovery | `ProjectionStore::cold_load(config, substrate)` |
| append | `append_record` / `append_writer_assigned` (+ `_reporting` variants) |
| read state | `get_state(execution_id)` / `list_executions()` |
| snapshot (storage) | `manifest_snapshot()` |
| flush / merge | `flush_and_wait()` / `run_pending_merges()` |
| **checkpoint** | ⚠ **not on `l0`** — `ProjectionCheckpoint` lives on stack B and is *derived by full replay*, not stored |

**The one genuinely missing piece is a stored per-partition cursor.** Everything
else is a function call away.

### Dependency mechanics — and a live hazard

Both consumers use a **git dependency pinned to a rev**, not a registry version
and not a path:

```toml
# server/Cargo.toml
ehdb-feed = { git = "…/ehdb", rev = "e4572492…" }
# worker/Cargo.toml
ehdb-reference|ehdb-service|ehdb-feed = { git = "…/ehdb", rev = "49fdefc…" }
```

> ⚠⚠ **The two consumers are 70 commits apart on the same engine.**

Today that is tolerable — they interact over a wire protocol, not a shared
format. **Under embedding it is not**: two processes opening engines against the
same on-disk layout at 70 commits of divergence is a corruption vector, and a
git-rev pin gives no mechanism that would even *notice*.

**Recommendation: publish `ehdb-*` to crates.io with semver, exactly as
`noetl-tools` and `noetl-executor` already are, and add a startup assertion that
the on-disk format version matches the crate's.** The pinned-rev scheme is the
one part of today's packaging that actively must not survive the pivot.

⚠ And note what #330/#331 just taught: a `feat:` that adds a public field ships
as a *minor* and breaks literal constructors, and a workspace member's version
can sit outside semantic-release entirely. Moving EHDB to the registry inherits
both hazards; they should be fixed there before, not after.

---

## 2. Per-consumer surface

| consumer | needs | crates | notes |
| :-- | :-- | :-- | :-- |
| **server** | event log + cache + projections, per owned partition | `ehdb-core`, `ehdb-l0` | drops `ehdb-feed` entirely — that is the network client |
| **worker** | local append log only | `ehdb-core`, `ehdb-l0` | today it pulls `reference` + `service` + `feed`; a local append log needs none of them |
| **gateway** | (future) SSE feed + KV read | see §4 — **recommended not to embed** | today pulls nothing; talks `:9105`/`:9107` |

### The feature split

`ehdb-l0` is one crate today. A clean split without breaking it:

- **default** — `core` + engine open/append/read. What the worker needs.
- **`projection`** — the fold, snapshot log, `cold_load`. Server only.
- **`replication`** — `ReplicaTarget`, `open_replicated`, `FailureDomain`. Off
  unless a genuinely separate substrate exists (⚠ [ehdb#332](https://github.com/noetl/ehdb/issues/332):
  prod's "replicas" were the same PVC, so this being on-by-default was itself a
  defect).
- **`serve`** — `ehdb-feed` / `ehdb-service`, i.e. the transport crates, which
  simply are not depended on by an embedded consumer.

⚠ **What blocks a clean split:** nothing structural — the graph already permits
it. What blocks it *practically* is that `ehdb-l0/src/projection.rs` and the
engine share a module tree and a `Dataset` trait, so `projection` as a feature
means moving types, and moving public types out of a crate that is git-pinned by
two consumers on different revs is the awkward part. **Do the registry move
first (§1), then the feature split.**

---

## 3. The in-process / transport line

### Where it falls

```
        ┌──────────────── one process, one shard ────────────────┐
  HTTP →│ API handler → ExecutionAffinity → owns()? ─ yes ─→ direct call → L0 engine
        │                      │                                  (no socket)
        └──────────────────────┼───────────────────────────────────┘
                               └─ no ──→ forward BY KEY to the owning shard
                                          (HTTP today; the only transport)
```

**Confirmed: no socket for local access.** The server would hold an
`Arc<L0Engine>` and call it. `ehdb-l0` has no network dependency, so this is not
a discipline — the dependency graph makes a local socket impossible to
accidentally introduce.

### What crosses the wire, and what does not

The transport is the **generalised affinity layer**, and it is essential to state
what it is *not*: it does not read or write storage on the caller's behalf. It
**relocates the request** to the process that owns the state, and that process
does the direct call.

| | carried |
| :-- | :-- |
| **key** | `execution_id` → `partition_for(id)` → `shard_for_partition(p, N)` — the mapping landed in server#417 |
| **payload** | the **request/record**, not storage bytes and not folded state — today `EventRequest` over `POST /api/events` with `AFFINITY_FORWARDED_HEADER` as the one-hop guard |
| **response** | the owner's **domain response** (`EventResponse`), verbatim |

> The distinction that keeps this from becoming a storage service again: a
> storage service answers *"give me these bytes"*; this answers *"you own this,
> you do it."* The former needs a consistency model, a retry policy, an
> idempotency key and a parity check at the boundary — which is the entire
> problem class ([#320](https://github.com/noetl/ai-meta/issues/320),
> [#325](https://github.com/noetl/ai-meta/issues/325)/[#326](https://github.com/noetl/ai-meta/issues/326))
> the pivot exists to delete. The latter needs only routing correctness, which
> server#416 made fail-closed.

### What still has to be generalised

`route_event` handles exactly one endpoint. Extending it needs, per §2 of the
main RFC, a classification of every keyed handler — and two things the current
layer does not have:

- **Fan-out**, for the bounded cross-execution reads. `for_each_shard` exists but
  loops over `DbPool`s; it becomes a parallel, partial-failure-aware scatter over
  peers.
- **Broadcast reads.** Catalog / credentials / keychain / runtime carry **zero**
  `execution_id` references and cannot route by this key. They stay on a
  cluster-master or a replicated read-only cache — the split
  `ExecutionService::list` already implements as *"per-shard fan-out +
  cluster-master catalog lookup"*.

---

## 4. Face migration — KEDA and the gateway

### KEDA: the live contract

```yaml
type: metrics-api
url:           http://noetl-cmdbus-writer-0.noetl.svc.cluster.local:9102/metrics
valueLocation: ehdb_feed_subject_lag{subject="commands.shared.shard.0"}
targetValue: 2          activationTargetValue: 1
scaleTargetRef: noetl-worker-rust      min 2 / max 20
```

It scales the **worker pool** off **command-bus backlog for the shared pool's
shard 0**. The signal survives the pivot — commands are still queued for
workers — and gets *better*: the server owning the embedded command bus knows
the backlog **without a network scrape**.

⚠ **But the server's existing lag metrics are not it.** Of 94 series on the
server's `/metrics`, 15 are lag/queue-shaped and **every one is mirror-shaped**:
`noetl_ehdb_eventlog_mirror_queue_depth`, `…_pending_events`,
`…_projection_mirror_queue_depth`, `…_crossstore_pending_total`. Those describe
the mirror — **the thing the pivot deletes**. Retargeting KEDA onto any of them
would point the autoscaler at a metric scheduled for removal.

**What the server must newly expose**, per owned shard:

| metric | replaces | why |
| :-- | :-- | :-- |
| `noetl_cmdbus_backlog{pool,shard}` gauge | `ehdb_feed_subject_lag{subject}` | the actual trigger; per-pool because the live trigger is per-pool |
| `noetl_cmdbus_committed{pool,shard}` counter | `ehdb_feed_shard_committed` | ⚠ [#208](https://github.com/noetl/ai-meta/issues/208): *"lag alone cannot"* distinguish a drained bus from a stalled consumer — the existing docs already say so, and dropping the companion would reintroduce that blindness |

⚠ **Pin both at 0 on startup.** `Registry::gather` prunes empty families, so a
labelled metric is absent until it fires — and an absent `valueLocation` makes
KEDA read *nothing*, which is not the same as reading zero.

**The ScaledObject change** is `url` → the server's own metrics endpoint and
`valueLocation` → the new name. ⚠ With N>1 there is no single URL: `metrics-api`
scrapes **one** address, so a sharded server needs either one ScaledObject per
shard (each scraping its own pod, scaling its own worker set) or a Prometheus
trigger over the aggregate. **That is a real design fork the retarget must
settle, and it does not exist at N=1** — which is the argument for doing the
retarget while still at one shard.

### Gateway: do **not** embed

The gateway holds `NOETL_EVENT_FEED_ADDR=…:9105` (SSE) and
`NOETL_KV_ADDR=…:9107` (KV), and pulls **no EHDB crates** today.

Embedding EHDB in the gateway would be wrong on the owner's own criterion. The
gateway is *"gatekeeper only … never reads or writes domain data on behalf of a
client"* (`execution-model.md`). Giving it a storage engine would give it its own
copy of state it does not own — the exact opposite of single-owner-per-shard, and
it would need its own partition ownership to be coherent.

**Recommendation: the gateway becomes a client of the owning shard, by key** —
the same generalised affinity path, not a storage socket:

- **KV (`:9107`)** — keyed reads. Route by the key's partition to the owning
  server shard; a normal API call.
- **SSE (`:9105`)** — the harder one. A subscription is not a point read: a
  client watching an execution should attach to that execution's **owner**, which
  is a partition-routed long-lived connection. A client watching *many*
  executions spanning shards needs fan-in from several owners.

⚠ **The SSE fan-in is the one piece of this design with no precedent in the
code.** Everything else is a generalisation of something that exists;
subscription routing across owners is new, and it should be designed before the
gateway's faces are touched. It is also the reason to migrate the gateway
**last**, after N>1 works for request/response.

---

## Recommended order (nothing authorised)

1. **Move `ehdb-*` to crates.io with semver**, retire the pinned-rev deps, and
   close the 70-commit skew. Everything else depends on the two consumers being
   able to agree on a version. Fix #330/#331's release hazards first.
2. **Pick the projection lineage** (recommended: `ehdb-l0`), and treat its
   unexercised state as such.
3. **Add the stored per-partition cursor** — the one missing primitive.
4. **Feature-split `ehdb-l0`** so the worker takes the append-only slice.
5. **Server opens a local engine** behind the existing seam, N=1, kind only.
6. **New cmdbus backlog + committed metrics on the server**, pinned at 0; retarget
   KEDA while still at N=1, and settle the per-shard-scrape fork.
7. Generalise affinity to fan-out and broadcast; N>1 in kind.
8. Gateway last: KV by key, then design SSE fan-in.

Steps 1–4 are library work with no prod surface at all.
