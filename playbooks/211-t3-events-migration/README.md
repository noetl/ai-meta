# T3 — migrate the `noetl.events.>` fan-out off NATS onto the EHDB feed bus

Status: **design complete; publish-side code shipped and merged; nothing
deployed to prod.** See "Implementation status" below for exactly what exists.
Surveyed 2026-07-31 against `gke_shastaratech-noetl-prod_us-central1_noetl-prod-autopilot`
(ns `noetl`, ns `gateway`, ns `nats`).

T3 is the last real blocker before T5 (delete NATS). The command bus is already
EHDB end-to-end and `NOETL_COMMANDS_RUST` is idle. What still binds NATS is the
**events** path.

Tracks [noetl/ai-meta#194](https://github.com/noetl/ai-meta/issues/194).
Prior audit: [`playbooks/210-t5-readiness/pre-t5-checklist.md`](../210-t5-readiness/pre-t5-checklist.md).

---

## Scope boundary — internal bus vs. user-facing tools

Everything in this runbook is about **internal** NoETL infrastructure. Read this
before acting on any "remove NATS" instruction here.

| | Internal | User-facing |
| :-- | :-- | :-- |
| **What** | command bus, event bus, KV, state | business-logic data and messaging |
| **Runs on** | **EHDB** | whatever external service the **user** brings |
| **Configured by** | platform env (`NOETL_COMMAND_BUS`, `NOETL_KV_ADDR`, …) | the playbook step (`url`) or a keychain credential alias |
| **NATS** | **removed** ([#212](https://github.com/noetl/ai-meta/issues/212)) | **`nats` tool kind — supported, stays** |

**EHDB is internal transient infrastructure and is never exposed as a user
store.** Users do not read or write EHDB; they point tools at their own
services.

**The `nats` tool kind is a supported user-facing feature**, one of several
(`postgres`, `duckdb`, `http`, `kafka`, object stores). Deleting the internal
bus does not make it dead — its endpoint comes from the playbook, not from
platform config. It lives in the separate `noetl-tools` crate with its own
`async-nats` dependency and was untouched by this migration.
[noetl/ai-meta#219](https://github.com/noetl/ai-meta/issues/219), which proposed
removing it, is closed as **won't remove**; the audit and end-to-end proof are
recorded there.

Practical consequence for anyone doing cleanup work in these repos: *"nothing in
the cluster carries a NATS URL"* is a statement about the internal bus only. It
is not evidence that a NATS-shaped code path is dead. Check whether the endpoint
comes from **platform config** (internal — may be dead) or from a **playbook /
credential** (user-facing — keep) before deleting anything.

---

## 0. The one thing that changes the risk calculus

`noetl-server-rust` runs with:

```
NOETL_EVENT_INGEST_PUBLISH_ONLY = true
```

Under this flag the server writes **zero** `noetl.event` rows. Every
server-originated event is published to the `noetl_events` JetStream stream, and
the worker-side `noetl_materializer` drains that stream and is the **sole writer**
of `noetl.event` (via `POST /api/internal/events/project`).

So `noetl.events.>` is not "SPA live updates". It is the **write path of the
append-only event log that is the platform's source of truth** — the log the
standing constraints say must never be lost. The prior audit framed the gateway
SSE loss as the user-visible risk; the durable-log risk is strictly larger and
sets the bar for every parity gate below.

Consequence for this migration: **no cutover step may ever leave the
materializer without a source.** Steps are ordered so the durable-log consumer is
cut over first, under dual-publish, with the NATS path still live behind it.

---

## 1. Publishers of `noetl.events.>`

One live publisher: **`noetl-server-rust`**.

| Call site | What it publishes | Subject |
|---|---|---|
| CQRS write-path tailer (`main.rs:880`) | batch-publishes committed `noetl.event` rows | `noetl.events.<event_type>` |
| `emit_events` chokepoint (`handlers/event_write.rs`, gated by `NOETL_EVENT_INGEST_PUBLISH_ONLY`) | all server-originated events; **the live prod path** | `noetl.events.<event_type>` |

Subject construction: `src/nats/event_publisher.rs:177` —
`format!("{EVENT_SUBJECT_PREFIX}.{event_type}")`, prefix `noetl.events`.
Stream `noetl_events` binds the wildcard `noetl.events.>`.

Stream config as deployed: `limits` retention, `max_age = 1d`, replicas 1,
dedup window 2m, file storage.

### 1a. A second, legacy subject shape still parsed downstream

The retired Python publisher (`noetl/core/messaging/nats_client.py::subject_for_event`)
used a **four-token** tail:

```
noetl.events.<tenant>.<organization>.<execution_id>.<shard>
```

The Rust publisher uses a **one-token** tail (`noetl.events.<event_type>`). The
gateway's `execution_id_from_subject` (`repos/gateway/src/playbook_state.rs:113`)
still parses the *Python* shape and reads `execution_id` from tail position 2.
Against the Rust shape that parse returns `None` — and that is **safe by
design**: `build_state_message` prefers `payload.execution_id` over the
subject-derived value, so the subject parse is a soft fallback.

**Implication for the EHDB design:** do not carry `execution_id` in the routing
subject. It is not reliably there today and nothing depends on it being there.
Route on `event_type`; read identity from the payload, as the gateway already
does.

---

## 2. Subscribers — four live consumers, two different delivery semantics

Verified on prod (`nats consumer ls noetl_events`, deployment env).

| # | Consumer | Mechanism | Semantics | Loses what if NATS dies |
|---|---|---|---|---|
| 1 | `noetl_materializer` | JetStream **durable pull**, filter `noetl.events.>`, explicit ack | at-least-once; **queue-group across the 2 system-pool pods**; own cursor | **the durable `noetl.event` log stops being written** |
| 2 | `noetl_result_materializer` | JetStream durable pull, own cursor | same | result tier (Feather/JSON) stops landing in object store |
| 3 | `noetl_state_materializer` | JetStream durable pull, own cursor | same | off-server state projection stalls |
| 4 | gateway `playbook_state` | **core NATS** `client.subscribe("noetl.events.>")` | **pure broadcast**, no ack, no replay, fire-and-forget | SPA live updates (`Muno is planning…` hangs) |

Consumers 1–3 are enabled by `NOETL_MATERIALIZER_ENABLED=true`,
`NOETL_RESULT_MATERIALIZER_ENABLED=true`, and the state materializer on
`noetl-worker-system-pool` **and** `-shard1` (both pods run all three).

`noetl_projector` is a fifth durable consumer with **17,301 unprocessed and
`last delivery: never`** — orphaned, drains nothing, safe to delete. Not in
scope here beyond noting it.

### 2a. The two semantics, stated precisely

This is the part that determines the EHDB primitive, so it is worth being exact:

- **Between** consumers 1/2/3 the relationship is **fan-out**: each has its own
  ack cursor and every event is delivered to all three independently.
- **Within** each of 1/2/3 the relationship is **queue-group**: the two
  system-pool pods compete, each record goes to exactly one pod, unacked records
  redeliver after `ack_wait`.
- Consumer 4 is **broadcast** with no cursor at all — a core NATS subscriber
  sees only what is published while it is connected.

So the events bus needs **both** modes at once: N named groups, each internally
a competing-consumer group, plus an uncursored broadcast tap.

---

## 3. What EHDB already has, and the one gap

`repos/ehdb/crates/ehdb-feed` (per-shard-writer-as-broker, topology (c)):

| Primitive | File | Fits which consumer |
|---|---|---|
| `FeedWriter::append` / `append_batch` (writer-assigned key, group commit, off-lock fsync) | `lib.rs` | the publish seam ✅ |
| `serve` — raw fan-out, `SubscribeReq{shard, cursor}`, **per-subscriber cursor** | `lib.rs` | broadcast ✅ |
| `serve_sse` — SSE, `Last-Event-ID` ↔ feed cursor, zero missed / zero duplicate on reconnect | `sse.rs` | **gateway SSE ✅ — written explicitly for T3** |
| `ShardConsumerGroup` / `SubjectConsumerGroup` — competing consumers, ack, `ack_wait` redelivery, committed cursor | `group.rs` | materializer queue-group ✅ |
| `Subject` / `SubjectFilter` — NATS-style `*` / `>` matching | `subject.rs` | subject routing ✅ |

**The answer to the design question the brief flagged:** EHDB feed is *not*
claim-only. `serve`/`serve_sse` are genuine fan-out — each subscriber holds its
own cursor over the shard log. Broadcast subscription exists.

**The gap:** `SubjectConsumerGroup` holds **one** `feed: ChangeFeed` cursor and
**one** global committed cursor (`group.rs:223-235`). It is a *single* group.
Three materializers need **three independently-cursored groups over the same
log** — the JetStream "three durable consumers on one stream" shape. That
primitive does not exist yet.

### 3a. The one new primitive to build

`ehdb-feed`: **named durable groups** — a registry of N `SubjectConsumerGroup`s
over one shard log, keyed by group name, each with its own `ChangeFeed` cursor
and its own persisted committed cursor.

- Wire: extend the claim protocol's subscribe frame with a `group` field
  (absent ⇒ today's default group, so the command bus is untouched).
- Durability: each group's committed cursor persists next to the writer's log,
  same shape as the command bus's `ehdb_feed_shard_committed`, so a writer
  restart resumes each group where it was. This is exactly the mechanism
  [#208](https://github.com/noetl/ai-meta/issues/208) hardened — reuse it, do
  not reinvent it.
- Metrics: per-group lag on the writer's `:9102`, so KEDA and the parity gates
  can read it.

---

## 4. Target topology

Events get their **own** L0 engine and their **own** ports, hosted in the same
writer pod (the writer is the `noetl-worker-rust` image with
`NOETL_COMMAND_BUS_HOST=true`; it already hosts ingest 9100 / claim 9101 /
metrics 9102).

```
noetl-server-rust
   │  publish (NOETL_EVENT_BUS)
   ├─────────────► NATS  noetl.events.<event_type>        [authoritative until step 3]
   └─────────────► EHDB  :9103 ingest ──► events L0 engine (/data/eventbus, own fsync)
                                              │
                    ┌─────────────────────────┼───────────────────────────┐
                    │ :9104 claim (named groups, ack, redelivery)         │ :9105 SSE
                    │                                                     │ (broadcast)
       ┌────────────┼─────────────┬──────────────────┐                    │
       ▼            ▼             ▼                  ▼                    ▼
  events_        events_       events_          (future)              gateway
  materializer   result_mat    state_mat                            playbook_state
  [group]        [group]       [group]                              [Last-Event-ID]
```

**Why a separate engine, not the command-bus engine.** [#205](https://github.com/noetl/ai-meta/issues/205)
established that the binding constraint on this design is `fsync` in the engine
lock. Events are far higher-volume than commands (17k events/day vs 2.2k
commands). Sharing one engine would put event volume directly in front of
command dispatch latency and re-open the exact regression #205 just closed.
Separate engine, separate `fsync` stream, separate directory.

**Sharding.** Prod runs `NOETL_COMMAND_SHARD_COUNT=1`, one writer
(`noetl-cmdbus-writer-0`). Events start single-shard to match. The events subject
carries a shard token for symmetry so multi-shard is a config change, not a
redesign.

**Subject.** `events.<event_type>` — the honest analog of
`noetl.events.<event_type>`. Per §1a, identity stays in the payload.

---

## 5. `NOETL_EVENT_BUS` — the flag

Mirrors `CommandBusMode` (`repos/server/src/command_bus.rs`) exactly, including
"anything unrecognised falls back to the safe default".

| Value | Server publishes to | Authoritative | Rollback |
|---|---|---|---|
| `nats` (**default**, and any unrecognised value) | NATS only | NATS | — |
| `shadow` | **both** NATS and EHDB | NATS | unset the var |
| `ehdb` | EHDB only | EHDB | set back to `shadow` |

Consumer-side selection is per-consumer and independent of the publish mode, so
a consumer can be cut over one at a time while publish stays in `shadow`:

| Var | Where | Values |
|---|---|---|
| `NOETL_EVENT_BUS` | server | `nats` \| `shadow` \| `ehdb` |
| `NOETL_EVENT_BUS_WRITER_ADDRS` | server | `0@noetl-cmdbus-writer-0…:9103` |
| `NOETL_MATERIALIZER_SOURCE` | system pool | `nats` \| `ehdb` |
| `NOETL_RESULT_MATERIALIZER_SOURCE` | system pool | `nats` \| `ehdb` |
| `NOETL_STATE_MATERIALIZER_SOURCE` | system pool | `nats` \| `ehdb` |
| `NOETL_EVENT_BUS_CLAIM_ADDR` | system pool | `noetl-cmdbus-writer-0…:9104` |
| `EVENT_BUS_SSE_URL` | gateway | `http://noetl-cmdbus-writer-0…:9105/feed` |

The three materializers already resolve their source through the `noetl_tools`
`SubscriptionConfig` abstraction (`materializer.rs::source_config` builds
`{"source":"nats",...}`). Adding an `ehdb` source there is the natural seam —
the drain loops themselves do not change.

---

## 6. Cutover order (each step reversible)

Ordered so the durable-log consumer is never sourceless, and so the
highest-risk consumer is proven first while the fallback is still live.

| Step | Action | Gate to pass before proceeding |
|---|---|---|
| **1** | Ship named-group primitive + `NOETL_EVENT_BUS`; deploy `shadow` (dual-publish). Consumers all still on NATS. | For a driven load window: EHDB event count == NATS event count, same `event_type` distribution, no gaps in the EHDB sort-key sequence. |
| **2a** | `noetl_state_materializer` → EHDB (lowest blast radius: projection rebuilds from the log). | Projected state matches the NATS-fed baseline for the same executions. |
| **2b** | `noetl_result_materializer` → EHDB. | Result-tier objects land for every over-budget result in the window. |
| **2c** | `noetl_materializer` → EHDB (**the durable log**). | `noetl.event` row count for the window matches exactly what the NATS-fed baseline wrote. Zero gaps. |
| **2d** | gateway SSE → EHDB. | Drive a real playbook; an SSE client receives the same lifecycle frames; async callbacks fire. |
| **3** | `NOETL_EVENT_BUS=ehdb` (stop NATS publish). Soak. | `noetl_events` message count flat at 0 new while all four consumers keep working. |
| **4** | **HOLD.** Report T3 migrated / T5-ready. | — NATS teardown is a separate, human-gated step. |

**If any gate fails: stop, roll back that step, report. Do not proceed toward
EHDB-only.**

---

## 6a. Implementation status (2026-07-31)

| Slice | State | Where |
|---|---|---|
| Named durable groups (`GroupCoordinator`) | **merged** | noetl/ehdb#306 → `25def72` |
| Events writer host (own engine, ports 9103/9104/9106) | **merged** | noetl/worker#199 → `8aa2fab` |
| `NOETL_EVENT_BUS` + dual-publish | **merged** | noetl/server#293 → `6894886` |
| `noetl_events_projected_total` (the cutover's ground-truth gate) | **merged** | noetl/server#294 → `f4f821a` |
| Writer IaC patch (ports, PVC, env — flag-neutral) | written, **not applied** | [`eventbus-writer-patch.yaml`](eventbus-writer-patch.yaml) |
| Parity tooling | written, smoke-tested against prod | [`parity-check.sh`](parity-check.sh) |
| **Materializer `ehdb` source (the consume half)** | **not built** | — |
| **Gateway SSE client** | **not built** | — |
| Release tags + images to AR | not done | — |
| Prod shadow deploy | **not done** | — |

Everything merged is **default-off**: `NOETL_EVENT_BUS` unset means `nats`,
`NOETL_EVENT_BUS_HOST` unset means the host never spawns and binds no port.
Prod is unchanged by any of it.

The next slice on the critical path is the materializer `ehdb` source in
`noetl/worker` — without it, `shadow` mirrors events onto a feed nothing reads,
which is a valid STEP 1 posture but cannot progress to STEP 2.

## 6b. What the build surfaced that the design did not predict

- **`events/project` had no metric.** The sole writer of the durable event log
  emitted only a log line, so "are rows still landing in `noetl.event`" had no
  queryable answer — and that is precisely STEP 2c's gate.
  `noetl_events_materialized_total` looks like it covers this but counts the
  *other* sink (`events/materialize`), which this deployment does not use; it is
  absent from prod's `/metrics` entirely because it has never been incremented.
  Fixed in noetl/server#294; the gate was unmeasurable before it.
- **`ehdb-feed` already had fan-out.** `serve` / `serve_sse` hold a
  per-subscriber cursor, and `sse.rs` was written for this exact T3 use. The
  design question "does EHDB support broadcast?" resolved to yes; the real gap
  was N independently-cursored *groups*, which is narrower and was the only new
  primitive needed.
- **Two subject shapes coexist on `noetl.events.>`** (§1a) — harmless today only
  because the gateway falls back to `payload.execution_id`.

## 7. Parity measurement

Prod is idle outside working hours (verified: `noetl_events` last message
2026-07-31 03:49:19, flat for ~3h at 06:46). Parity cannot be observed
passively — it must be **driven**. Reuse
[`playbooks/210-t5-readiness/drive-load.sh`](../210-t5-readiness/drive-load.sh),
which is already calibrated for this cluster.

Counters to compare over the same window:

- NATS: `nats stream info noetl_events` → `state.messages` delta, and per-consumer
  `delivered.stream_seq` delta.
- EHDB: writer `:9102` → events-feed appended count, per-group committed cursor.
- Server: `noetl_events_published_total` (already exists, `metrics.rs:825`) vs the
  new EHDB publish counter, by `event_type`.
- Durable log: `SELECT count(*) FROM noetl.event WHERE …window…` — the ground
  truth that consumer 1 is doing its job.

A parity claim needs **all four** to agree, not just the stream counter. Counting
only what was published proves the publisher, not the consumers.

---

## 8. Scope boundary — what T3 does *not* cover

NATS carries three surfaces beyond `noetl.events.>`. They are **not** part of T3
and each independently blocks T5:

1. **`noetl.callbacks.>`** — gateway `callbacks.rs` core-NATS subscribe for async
   playbook results. Different subject space entirely.
2. **NATS KV `sessions`** — gateway session cache. Degrades to Postgres lookups
   (#168 sync fast-path covers the hot path). Tolerable but live.
3. **NATS KV `requests`** — gateway request store. Its loss is what actually
   breaks async callbacks (the audit's B2).

Both KV buckets currently read `Last Update: never` and are empty, but the code
paths that populate them are live. **T5 must not be attempted until these three
are resolved too** — T3 alone is necessary, not sufficient.

---

## Related

- [`ROLLBACK.md`](ROLLBACK.md) — per-stage rollback recipes.
- [`playbooks/210-t5-readiness/pre-t5-checklist.md`](../210-t5-readiness/pre-t5-checklist.md) — the audit this continues.
- [`docs/rfc/ehdb-nats-takeover-plan.md`](../../docs/rfc/ehdb-nats-takeover-plan.md) — T0–T5 arc; T3 is line 364, G6 is line 79.
- [noetl/ai-meta#194](https://github.com/noetl/ai-meta/issues/194) — the L1 takeover umbrella.
- [noetl/ai-meta#188](https://github.com/noetl/ai-meta/issues/188) — plaintext `noetl:noetl` credential, retired for free by T5.
