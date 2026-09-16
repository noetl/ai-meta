# server#203 — CQRS phase 2b: survey + plan

**Status: plan only. Nothing built. Held for owner review.**
Surveyed 2026-09-16 against `noetl/server` main, `noetl/worker` main, kind and prod.

## 1. What the issue asks for

- **2b-1 (server):** `POST /api/internal/projection/advance` + a
  `NOETL_PROJECTOR_OWNS_SNAPSHOT` gate so the orchestrator stops self-writing
  `noetl.projection_snapshot`.
- **2b-2 (playbook):** a `system/projector` **catalog playbook** — a
  **`noetl_events` JetStream batch consumer** that extracts execution_ids, posts
  them to `/projection/advance`, then acks.

## 2. What is already in place

### ✅ 2b-1 is DONE — all three parts

| part | where |
| :-- | :-- |
| the endpoint | `main.rs:230` → `handlers::internal::projection_advance` (`internal.rs:421`) |
| the handler | de-duplicates execution_ids, advances each via `events::advance_snapshot`, records `record_projection_advanced`, collects per-execution failures rather than failing the batch, behind `RequireInternalApiToken` |
| the gate | `config/app.rs:58-68`, `projector_owns_snapshot`, **default false** |
| the wiring | `events.rs:3404 / 3423 / 5210` — the orchestrator reads the snapshot instead of self-writing when set |

Nothing to build here. It is complete and inert by default.

### ❌ 2b-2 is NOT done

No `system/projector` exists in any repo, in kind's catalog, or in prod's catalog.

## 3. ⚠ Two ways the 2b-2 spec is stale

This is the substance of the survey, and it changes what should be built.

### 3a. "Catalog playbook" — its sibling shipped as a worker loop

Phase 2d's `system/event_materializer` is described in exactly the same words
(`config/app.rs:110`: "the `system/event_materializer` **playbook** becomes the
sole `noetl.event` writer"). It is **not a playbook.** It is a worker background
loop — `noetl/worker` `src/materializer.rs`, `enabled()` on
`NOETL_MATERIALIZER_ENABLED`, `spawn()`, two drain loops — and it is
**running on the system pool in kind AND prod today**
(`NOETL_MATERIALIZER_ENABLED=true` on both).

The only genuine `system/*` catalog artifact is `system/orchestrate`, and that is
a **WASM plug-in** (`plugins/orchestrate` → `orchestrate.wasm`, seeded from
`/opt/noetl/plugins` by `system_plugins.rs`), not a playbook either.

So "catalog playbook" describes neither sibling.

### 3b. ⚠⚠ The `noetl_events` stream does not exist

Queried NATS in kind directly (`/jsz?streams=1&consumers=1`):

```
streams = 1
  stream=NOETL_COMMANDS  msgs=1080  consumers=5
```

**There is no `noetl_events` stream.** And the materializer — the thing that
would consume it — runs with `NOETL_MATERIALIZER_SOURCE=ehdb` in both kind and
prod. The live event transport is the **EHDB bus**, not a JetStream
`noetl_events` stream.

A projector written literally to spec would subscribe to a stream that is never
created and silently process nothing — which is exactly the failure class this
codebase keeps paying for.

## 4. Smallest correct increment

A **projector drain loop in the worker**, modelled directly on `materializer.rs`:

1. `worker/src/projector.rs` — `enabled()` on `NOETL_PROJECTOR_ENABLED`
   (**default off**), `ProjectorConfig::from_env` (fails loud when enabled but
   missing the internal token, as the materializer does), `spawn()`.
2. A drain loop over the **same source abstraction** the materializer uses
   (`EhdbGroupSource` / `build_source`, honouring `*_SOURCE=ehdb|nats`), so it
   consumes whatever transport is actually live rather than a hard-coded one.
3. Per batch: extract the **distinct** `execution_id`s, `POST` them to the
   existing `/api/internal/projection/advance`, then ack — **ack-after-advance**,
   mirroring the materializer's ack-after-materialize.
4. Reuse the bounded HTTP client added in worker#324 (no unbounded waits).
5. Worker-side counters mirroring the materializer's; the server side already
   has `record_projection_advanced`.

**Blast radius: zero until two flags are flipped.** `NOETL_PROJECTOR_ENABLED`
off ⇒ no loop runs. `NOETL_PROJECTOR_OWNS_SNAPSHOT` off ⇒ the orchestrator
self-writes exactly as today. Both already default off.

**Proof plan:** unit tests on batch → distinct-execution-id extraction and on the
ack disposition; a defect-planting control for each (drop the dedup ⇒ duplicate
advances; ack before advancing ⇒ a dropped batch is not retried); kind proof with
the flag on, showing `projection_snapshot` advancing from the projector and the
orchestrator no longer writing it, with the shadow comparison against the
orchestrator's own snapshot.

## 5. ⚠ What needs an owner decision

1. **Delivery mechanism.** The issue says catalog playbook; the evidence says
   worker loop. I recommend the worker loop (its sibling works, is deployed, and
   is the pattern the transport supports) — but it contradicts the issue text, so
   confirm before I build.
2. **Transport.** Build against the EHDB source (live) rather than
   `noetl_events` (does not exist)? If a `noetl_events` stream is genuinely
   planned, that is a separate prerequisite and 2b-2 is blocked on it.
3. **Partial-failure policy.** `/projection/advance` returns `advanced[]` **and**
   `failed[]`. What should the consumer do with a partially-failed batch — ack
   all, ack only the advanced, or nack the failures for redelivery? This is a
   durability choice, not an implementation detail. The materializer has an
   `AckDisposition` precedent I can mirror, but "what counts as success" is yours.
4. **The flip itself** is explicitly owner-gated by the existing doc: "flip on
   only once the projector is confirmed running, or the snapshot stops advancing
   and rebuild cost grows."

## 6. Observation, not a finding

kind's `NOETL_COMMANDS` consumers `noetl_worker_pool_system_shard0` and
`shard1` each show **512 pending**. `noetl-worker-system-pool-shard1` is scaled
to **0 replicas** in kind, so a permanent backlog there is expected config, not a
defect. Noting it only so it is not mistaken for one later.
