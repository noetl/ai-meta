# RFC: Does NoETL still need NATS, or can EHDB replace it?

**Status:** RFC — analysis only. READ-ONLY. No code change proposed to land
from this document; it exists to inform a human decision.
**Date:** 2026-07-15.
**Author:** agent session (ai-meta).
**Related prior art:**
[RFC: EHDB Completion Program — Server↔EHDB Coupling + Storage Substrate](https://github.com/noetl/ai-meta/wiki) (`ehdb-wiki/RFC-Server-EHDB-Coupling-and-Storage-Substrate.md`),
[Design: Event-Log Core Engine (Phase 6)](https://github.com/noetl/ehdb) (`ehdb-wiki/Design-Event-Log-Core-Engine.md`),
[Object-Store-Backed Sharded State Builder](https://github.com/noetl/docs) (`repos/docs/docs/architecture/sharded_state_builder.md`),
ehdb#241 (completion program), ehdb#254 (durable event-log), ai-meta#178
(EHDB query interface), ai-meta#166 (command sharding), ai-meta#116
(execution affinity), ai-meta#188 (plaintext NATS credential).

---

## TL;DR

NATS plays **at least seven distinct roles** in NoETL. They split cleanly
into two families:

- **Storage roles** — durable event log, KV coherence state, object/blob
  spool. EHDB is a plausible per-tier replacement for these, and the
  program (ehdb#254 durable segment backend, Phase 6–10 driver interface,
  ai-meta#178 query surface) is *already building exactly that*.
- **Transport / coordination / autoscaling roles** — push-style command
  wakeup, durable-consumer work distribution with at-least-once
  redelivery, hierarchical subject filtering for sharding + affinity, and
  the per-consumer-lag signal KEDA scales on. **EHDB does not provide any
  of these today, and JetStream-compatible transport is an explicit
  non-goal of EHDB's first milestone** (`ehdb-wiki/Architecture.md:1101`).

**Verdict:** *Yes for the storage roles; no (and hard) for the transport
roles.* "Replace NATS completely" would require building a
push/subscribe/ack-redelivery/consumer-group/lag-export transport layer —
i.e. re-implementing JetStream — or degrading the command/drive path to
**polling**, which regresses the exact per-hop latency floor the
ai-meta#130 / #156 work spent months lowering, and dismantles the KEDA
autoscaling signal.

**Recommendation:** Option (a) — **partial replacement.** Keep NATS as the
real-time command/drive bus, work-distribution layer, and KEDA lag source.
Move the durable event *store*, projections, and (carefully) KV/object
tiers to EHDB behind the per-tier driver interface that already exists.
This is the direction the program is implicitly already on. See
§5 for the human decisions this forces.

---

## 1. What NATS actually does today (code-cited inventory)

Client library: **`async-nats = "0.38"`** in all four Rust crates
(`repos/server/Cargo.toml:98`, `repos/worker/Cargo.toml:295`,
`repos/tools/Cargo.toml:81`, `repos/cli` transitively). The Python
runtime (`repos/noetl`) is **fully off NATS** — only test doubles remain.

### Role 1 — Durable event storage (JetStream streams)

Two File-backed JetStream streams:

- **`noetl_events`** — the CQRS write-path WAL. Config at
  `repos/server/src/nats/event_publisher.rs:140-155`:
  `subjects: ["noetl.events.>"]`, `storage: File`, `duplicate_window`
  (dedup by `Nats-Msg-Id = event_id`), `max_age` (retention).
  Retention/dedup are env-driven: `NOETL_EVENT_STREAM_RETENTION_SECS`
  default **86 400s (24h)**, `NOETL_EVENT_STREAM_DEDUP_SECS` default 120s
  (`repos/server/src/services/event_stream.rs:97-102`). The stream is fed
  by a tailer that reads committed `noetl.event` rows past a persisted
  cursor and batch-publishes them.
- **`noetl_commands`** — the command-notification queue. Config at
  `repos/server/src/nats/publisher.rs:111-117`: `max_age: 3600s (1h)`,
  `storage: File`. Explicitly a *"best-effort notification channel,"*
  contrasted with `noetl_events` the *"durable write log"*
  (`event_publisher.rs:143-144`).

> **Entanglement to note:** `noetl_events` is simultaneously a **store**
> *and* a **transport** — the materializer, projector, result-materializer,
> state-materializer, and state-builder all consume it in real time (Role
> 3). "Move the event store to EHDB" therefore is not cleanly separable
> from "keep the event transport on NATS" — see §3.1.

### Role 2 — Real-time transport / command wakeup (pub/sub)

Server publishes a **pointer, not the command body**, to JetStream and
waits for the durable PubAck — `repos/server/src/handlers/execute.rs:1679-1684`:

```rust
let js = async_nats::jetstream::new((**nats_client).clone());
js.publish(subject.clone(), payload.into()).await?  // publish
    .await?;                                          // await stream PubAck
```

Payload = `{execution_id, event_id, command_id, step, server_url,
execution_pool}` (`execute.rs:1657-1668`). The worker pulls the
notification, then **claims the actual command back over HTTP** against the
publishing server — `repos/worker/src/nats/source.rs:337-341`
(`claim_command(event_id, worker_id)`). If `state.nats` is `None` the
server logs a warning and skips — NATS is *optional* and the system
degrades to slower polling (`execute.rs:1606-1613`).

### Role 3 — Work distribution / consumer coordination

The command consumer is a **durable pull consumer** — one durable per
pool, shared by all replicas of that pool, giving queue-group-like
load-balancing. `repos/worker/src/nats/subscriber.rs:252-256`:

```rust
let consumer_config = ConsumerConfig {          // pull::Config
    durable_name: Some(self.consumer.clone()),  // e.g. "worker-pool"
    filter_subject: self.subject.clone(),        // = NATS_FILTER_SUBJECT
    ..Default::default()  // => AckPolicy::Explicit, max_deliver=-1, ack_wait≈30s
};
```

Delivery is **at-least-once with unlimited redelivery**; the exactly-once
gate is the **DB `claim_command`**, not NATS (a redelivered notification
re-claims → `AlreadyClaimed` → ack, no re-exec —
`repos/worker/src/worker.rs:437-583`). Ack/nak at
`subscriber.rs:318-350`.

Three more durable consumers on `noetl_events`, each its own cursor
(`repos/server/src/nats/event_publisher.rs:52-70`): `noetl_projector`,
`noetl_materializer`, `noetl_result_materializer`; plus worker-side
`noetl_state_materializer` (`repos/worker/src/state_materializer.rs:247`)
and the state-builder WAL-index drain (default **ephemeral
`DeliverPolicy::All`** consumer that cold-replays the retained 24h WAL on
every boot — `repos/worker/src/state_builder.rs:1352`).

### Role 4 — Per-shard subjects (ai-meta#166 command sharding)

`repos/server/src/sharding.rs:241-254`:

```rust
if shard_route && command_shard_count > 1 && pool == "system" {
    let n = shard_for(execution_id, command_shard_count); // XxHash64(eid) % count
    format!("noetl.commands.{pool}.shard.{n}.{execution_id}")
} else {
    format!("noetl.commands.{pool}.{execution_id}")
}
```

Only the **system pool** (the drive pool) is shard-routed. Per-shard
consumers are pure **ops/env** — each worker binds one durable consumer
with `filter_subject = noetl.commands.system.shard.<n>.>` (validated in
prod 2026-07-13, ai-meta#166 Phase 5). The shard subject is a subtree of
`noetl.commands.system.>`, so a broad-filter replica still receives a
shard-routed command and degrades to the NAK-redirect path — this
**subject-subsumption invariant** (`sharding.rs:228-234`) is load-bearing
and any replacement must preserve it.

### Role 5 — Execution affinity (ai-meta#116 / #166 Phase 4)

Affinity uses NATS at the command layer two ways: (a) sharded subject
filtering routes a drive command straight to the owning replica's
consumer; (b) a non-owner replica **NAKs-with-delay** to steer a drive
command to its owner — `repos/worker/src/nats/source.rs:272-312`
(`DRIVE_STEP_NAME = "__orchestrate__"`), bounded by
`NOETL_STATE_AFFINITY_MAX_REDIRECTS`, falling back to local cold-load.
A NAK-before-claim performs no claim and emits no event, so redirects
never drop or double-process a hop.

### Role 6 — KV / coherence state

Two JetStream **KV buckets** for multi-replica coherence —
`repos/server/src/coherence.rs:65-68`: `noetl_chain_heads`
(execution_id → chain-head event_id) and `noetl_exec_descriptors`
(execution_id → descriptor JSON). Config `history: 1`, File storage
(`coherence.rs:149-154`). Access is **CAS** (`store.update(key, val, rev)`
with 6 retries — `coherence.rs:188-216`). Gated by
`NOETL_REPLICA_COHERENCE=nats_kv`; default `local` (in-memory, KV off).
**These are read and written by the stateless server edge** — a
control-plane role.

### Role 7 — Object / blob

`NatsObjectBackend` for spool overflow (`repos/tools/src/spool/backend.rs:170`),
one impl of the `SpoolBackend` trait alongside `gcs` / `s3` / `local_disk`.
Plus the playbook-facing `tool: nats` (`repos/tools/src/tools/nats.rs`)
exposing KV / object / JetStream ops with **playbook-supplied** bucket
names — this is a *business-facing connector*, out of scope for platform
replacement.

### Role 8 — Backpressure / autoscaling signal (the sleeper dependency)

**KEDA scales the worker pools on JetStream per-consumer lag, read
directly from the NATS monitoring endpoint** — not from a Prometheus
gauge. `repos/ops/ci/manifests/keda/scaledobject-worker-system-pool.yaml:49-58`:

```yaml
triggers:
- type: nats-jetstream
  metadata:
    natsServerMonitoringEndpoint: nats.nats.svc.cluster.local:8222
    stream: NOETL_COMMANDS
    consumer: noetl_worker_pool_system
    lagThreshold: '10'
```

The worker also polls `consumer.info()` every 5s and exports
`noetl_worker_nats_consumer_pending` / `_ack_pending`
(`repos/worker/src/nats/lag_poller.rs`, `subscriber.rs:398-419`). This is a
**hard NATS dependency for autoscaling**: replacing NATS on the command
path requires an equivalent per-consumer-lag surface the KEDA
`nats-jetstream` trigger (or a replacement scaler) can read.

### Role 9 — Reconnect / self-heal (ai-meta#163)

On `origin/main` (`a5fe22a`) the worker command loop self-heals a hard
NATS disconnect **in-process** by rebuilding the subscriber and
**re-binding the same durable consumer by name** — its server-side cursor
is unchanged, so no command is replayed or skipped
(`worker.rs` `a5fe22a`:703-738). This depends on the **durable consumer's
server-side cursor surviving a client reconnect** — a JetStream durability
property. (Note: the currently checked-out worker tree is on
`feature/duckdb-integration-passthrough`, which forks before `a5fe22a` and
lacks the in-process reconnect — it crash-restarts instead. Roles 1–4 are
identical on both lines.)

### What NATS is NOT load-bearing for

**Exactly-once** and **cross-command ordering**. Exactly-once is the DB
`claim_command` gate; ordering is server-side execution affinity +
in-memory `ChainHeads`. NATS provides *at-least-once* and
*subject-scoped* delivery, and the platform is built to tolerate
duplicate/reordered notifications. This matters: it means the transport
requirement is "wake a worker, at-least-once, filtered by subject, with a
lag signal" — not "totally-ordered exactly-once delivery."

---

## 2. What EHDB actually provides (capability boundary)

EHDB is an **Arrow-native storage + ordering + query engine**. Crates:
`ehdb-core`, `ehdb-catalog`, `ehdb-storage`, `ehdb-stream`,
`ehdb-transaction`, `ehdb-system`, `ehdb-retrieval`, `ehdb-reference` (the
tier engines: `eventlog.rs`, `durable_eventlog*.rs`, `projection.rs`,
`kv.rs`, `object.rs`, `vector.rs`), and `ehdb-service` (a **read-only**
Arrow Flight gRPC surface).

### It is storage + query. It is NOT a transport.

This is the crux, and the code is unambiguous.

- **Every read is a stateless PULL that returns immediately.** The
  event-log driver (`ehdb-reference/src/eventlog.rs:226-242`) is
  `append` / `scan_global` / `read_execution` / `tail` / `ack`, all
  `&self`, *"the engine is stateless per call (durable state lives in the
  on-disk transaction log, opened + dropped per op)"* (`eventlog.rs:224`).
  `tail` is a **bounded tail pull** that *"does not move the ack cursor"*
  (`eventlog.rs:238`); if the log is empty it returns `pending_count: 0`
  at once and never blocks (`durable_eventlog.rs:1055-1109`).
- **No push, subscribe, notify, or watch.** A repo-wide grep across
  `ehdb/crates` + `worker/src/ehdb` for `.recv(`, `block_on`, `wait_for`,
  `Condvar`, `Notify`, `broadcast`, `watch(`, `.subscribe(`, background
  loop, `poll_interval`, `sleep` returned **zero hits**. The only
  `tokio::sync` use anywhere is a `Semaphore` for gRPC request-limiting.
  The design docs say it outright: the durable consumer acks *"without a
  background subscription loop"* (`ehdb-wiki/Roadmap.md:531`).
- **No consumer-group fan-out, no server-managed redelivery.** At-least-once
  exists via a persisted per-named-consumer ack cursor, but "redelivery"
  is simply "the next `tail` re-returns un-acked records." There is no
  visibility-timeout, no nack, no load-balancing across a group. Each named
  consumer keeps its own cursor.
- **Cross-process is share-a-durable-medium + cold-load + replay, never
  notification.** The shared-tier slice (ehdb#254) has a single writer per
  shard publish segment bytes to a shared object store; a non-owner
  **cold-loads and replays** those segments (`durable_eventlog_shared.rs`).
  Even the "must see a just-appended event" case is met by making publish
  synchronous — *the reader still has to go read it; it is not signalled*.
- **The query interface (#178) is read-only, point-in-time, bounded.**
  `noetl ehdb query …` (`repos/cli/src/main.rs:466-560`) hits `GET
  /api/ehdb/*` (all `get(...)` routes, `repos/server/src/main.rs:334-355`);
  the worker handler is *"read-only … no append/put/upsert/delete path is
  reachable here"* (`repos/worker/src/ehdb/query.rs:22-24`). The server
  binary links **no EHDB data-plane engine** (`main.rs:331`). Arrow
  Flight `do_get` streams a **finite** already-materialized result;
  `do_put` / `do_exchange` / `do_action` are `unimplemented`
  (`ehdb-service/src/lib.rs:2837-2871`).
- **It says so.** *"Reads do not ride the NATS drive/command bus"*
  (`repos/worker/src/ehdb/query.rs:7-9`). The coupling RFC's tunable-backend
  table lists EHDB as the swappable backend for the **event-log,
  projection, KV, object, and vector** tiers only — **the command
  drive/dispatch bus is not in that table**
  (`RFC-Server-EHDB-Coupling-and-Storage-Substrate.md:172-178`). And
  EHDB's own non-goals for the first milestone include *"Full NATS
  JetStream compatibility,"* *"Production consensus implementation,"* and
  *"Multi-region replication"* (`ehdb-wiki/Architecture.md:1101-1114`).

### Maturity caveat

Everything EHDB is **default-off, kind-only, nothing in prod** (all
`NOETL_EHDB_*` default off; primary-serve is compile-time disabled —
`PRIMARY_SERVE_ACTIVATED = false`). The durable substrate is a local
JSONL/segment reference; **cross-node replication and consensus (Raft) are
explicitly deferred** behind the transaction-log trait
(`ehdb-wiki/Architecture.md:961-983`). So even the storage-tier
replacement is not yet a distributed, HA store.

---

## 3. Role-by-role replaceability verdict

| # | NATS role | EHDB replace? | Why |
|---|---|---|---|
| 1 | Durable event **store** (`noetl_events` as durable log) | **Yes (in progress)** | ehdb#254 durable_segment covers append / replay / KeepAll retention / global monotonic ordering / per-execution subject scoping. Gaps: distributed replication + consensus deferred; sharded multi-stream ordering not yet aligned with #166; primary-serve disabled. |
| 2 | Real-time transport / command wakeup | **No** | No push. A worker could only *discover* a command by polling `tail`. Reintroduces the per-hop latency #130/#156 removed. |
| 3 | Work distribution / consumer coordination | **No** | No consumer-group load-balancing, no server-managed redelivery/ack-wait, no NAK. Would have to be rebuilt. |
| 4 | Per-shard subjects (#166) | **No** | Depends on hierarchical subject + wildcard filtering as the routing seam. EHDB has subject *filters for replay*, not a routing bus. |
| 5 | Execution-affinity NAK steering (#116) | **No** | Rides Roles 3+4. No NAK/redirect primitive in EHDB. |
| 6 | KV coherence (`chain_heads` / `exec_descriptors`) | **Partial / blocked** | EHDB KV tier could hold the data, but these are read/written by the **stateless server (control-plane) edge**, which the coupling RFC *denies* EHDB data-plane access (Decision 1). Moving them into EHDB breaches the loose-coupling boundary. Needs CAS. |
| 7 | Object / blob spool | **Yes (easy)** | Already trait-abstracted (`SpoolBackend`); gcs/s3/local are alternatives. EHDB object tier is another impl. Non-real-time. |
| 8 | KEDA lag / backpressure signal | **No (today)** | KEDA reads JetStream `num_pending`/`num_ack_pending` via the NATS monitoring endpoint. EHDB exposes no per-consumer-lag surface a scaler can read. |
| 9 | Durable-cursor-surviving-reconnect self-heal | **N/A** | This is a *property* of durable consumers; whatever provides Role 3 must provide it. |

### 3.1 The store/transport entanglement

Roles 1 and 3 share the `noetl_events` stream. If EHDB becomes the durable
store but NATS keeps the transport, `noetl_events` still exists on NATS for
the real-time consumers (materializer/projector/state-builder), and EHDB
becomes a durable, replayable, queryable mirror + serve surface (which is
exactly the Phase 6 shadow → primary-serve shape). If instead those
consumers read from EHDB's `tail`, each becomes a **polling loop** — fine
for the already-batched materializers (500 events / 500ms), but the
state-builder drive path is latency-sensitive and should stay push. The
honest framing: **EHDB can be the source-of-truth store and the query/replay
surface; NATS stays the low-latency fan-out for the hot consumers.**

---

## 4. Options, ranked

### (a) Partial replacement — NATS transport, EHDB store *(recommended)*

Keep NATS for Roles 2–5, 8, 9 (command bus, work distribution, sharding,
affinity, KEDA lag, reconnect). Move Roles 1, 7, and the projection tier to
EHDB behind the per-tier `EventLogDriver` / driver interface; treat Role 6
(coherence KV) as a separate decision (§5.2).

- **Buys:** the event-sourcing bottleneck fix the whole program targets
  (bounded WAL index, durable replayable log, sharded state store), one
  storage fabric for the log/projections/object/vector tiers, dual-run
  shadow with documented rollback per tier.
- **Costs:** NATS stays a dependency (does not reach the "k8s-only"
  end-state of coupling-RFC Decision 2 for the transport). One more moving
  part during dual-run.
- **Breaks:** nothing if gated per the existing shadow→primary discipline.
- **Migration:** *already scaffolded* — ehdb#254 (durable backend), the
  `EventLogDriver` trait (Phase-10 tunable), ai-meta#178 (query/replay
  surface), the Phase 6 shadow/parity harness. The remaining work is
  primary-serve cutover per tier + a JetStream `EventLogDriver` impl to keep
  the tier selectable.
- **Risk:** low-moderate, incremental, reversible per tier.

### (b) Full replacement — EHDB + polling

Replace NATS entirely; workers poll EHDB `tail`/`scan` for commands.

- **Buys:** the k8s-only self-sufficiency goal, literally.
- **Costs:** reintroduces per-hop drive latency bounded by the poll
  interval — a direct regression of ai-meta#130/#156 (which fought the
  multi-second per-hop floor *down*); loses at-least-once *transport*
  redelivery (must be rebuilt on cursors + a redelivery timer); loses the
  KEDA `nats-jetstream` lag signal (must build an EHDB pending-count
  surface + a new scaler *before* cutover); polling N shards × M pods
  against a shared object store is a new load pattern.
- **Breaks:** autoscaling, and the latency SLO the drive path is tuned to.
- **Risk:** high. Not recommended.

### (c) Full replacement — EHDB + a new lightweight transport

Replace NATS; build a push/subscribe/ack/consumer-group/lag-export layer
(in EHDB or beside it).

- **Buys:** self-sufficiency without polling latency.
- **Costs:** you are re-implementing JetStream — durable consumers with
  server-side cursors, ack-wait/redelivery, queue-group load-balancing,
  hierarchical subject routing, a monitoring/lag endpoint, and reconnect
  semantics. EHDB explicitly lists this as a **non-goal**
  (`Architecture.md:1101`). Multi-quarter, high-risk, and it competes for
  the same engineering the storage-tier fix needs.
- **Risk:** high; poor effort/reward vs (a). Not recommended near-term.

### (d) Keep NATS as-is, EHDB stays storage-only for its own tiers

Status quo: NATS for everything it does now; EHDB progresses on its tiers
independently.

- **Buys:** zero migration risk.
- **Costs:** keeps the external NATS dependency (and ai-meta#188's plaintext
  credential surface); does not realize the event-log bottleneck fix.
- **Risk:** none technical; it just defers the value EHDB exists to deliver.

### Is the program already heading toward (a)?

**Yes.** ehdb#254 builds a durable event-log *store*; ai-meta#178 builds a
read/replay *query* surface; the Phase 6 design is an explicit shadow →
primary-serve *store* cutover; the coupling-RFC tunable-backend table
scopes EHDB to the **store** tiers and pointedly omits the command bus. The
sharded-state-builder RFC keeps NATS as *"the routing seam — the command
goes to the owning consumer group"* and layers object-store/EHDB as the
*storage* substrate underneath. Every artifact points at (a). The gap is
that coupling-RFC **Decision 2** ("no external infra dependency except
Kubernetes") is written as if (a) and full self-sufficiency are the same
endpoint — they are not, because of the transport roles. §5.1 is that
reconciliation.

---

## 5. Recommendation & the human decisions

**Recommend Option (a): partial replacement.** NATS remains NoETL's
real-time command/drive bus, work-distribution layer, sharding/affinity
routing seam, and KEDA autoscaling source. EHDB becomes the durable event
*store*, projection engine, and object/vector tiers behind the per-tier
driver interface, cut over shadow → primary per tier with documented
rollback. Do **not** pursue removing NATS from the command path without
first funding a transport replacement (option c) — and that is a
multi-quarter effort against an EHDB non-goal.

The load-bearing things a "replace NATS completely" move would silently
trade away — flagged so they are traded *knowingly*, not by accident:

1. **Push-delivery latency.** Polling replaces sub-second wakeup with
   poll-interval latency on the drive hot path (regresses #130/#156).
2. **At-least-once *transport* redelivery.** Today an unacked notification
   redelivers indefinitely (`max_deliver=-1`, `ack_wait≈30s`) until the DB
   claim collapses duplicates. A cursor-only store has no redelivery timer.
3. **Backpressure / autoscaling.** KEDA scales on JetStream per-consumer
   lag. No equivalent EHDB surface exists; autoscaling breaks the day NATS
   leaves the command path unless a replacement lag signal ships *first*.
4. **Crash-recovery semantics.** The durable-consumer-cursor-survives-
   reconnect property (#163) is what makes NATS bounces non-catastrophic.

### Decisions that need the human

- **5.1 — Reconcile coupling-RFC Decision 2 with transport reality.**
  Decide explicitly: is *"NATS-the-transport"* exempt from the "k8s-only,
  no external dependency" self-sufficiency goal (making the goal "no
  external *storage* dependency")? Or is a transport replacement (option c)
  a funded initiative? Recommendation: adopt the former — scope
  self-sufficiency to the storage tiers; keep NATS as a k8s-native
  in-cluster transport (it already runs in-cluster).

- **5.2 — Coherence KV boundary (Role 6).** `noetl_chain_heads` /
  `noetl_exec_descriptors` are written by the **stateless server edge**,
  which coupling-RFC Decision 1 denies EHDB data-plane access. Choose:
  (i) keep them on NATS-KV; (ii) move them to a control-plane store that is
  neither NATS nor an EHDB data plane (e.g. a Postgres coherence row, or
  the control-plane read-cache exception in the coupling RFC); or (iii)
  amend Decision 1 for this specific CAS surface. Recommendation: (i) or
  (ii) — do not breach the loose-coupling boundary for a hot-path CAS.

- **5.3 — Ordering constraint on any NATS-off future.** If the command
  path ever leaves NATS, a replacement per-consumer-lag surface + KEDA
  trigger must land and be validated **before** cutover, not alongside it.
  This is a hard sequencing constraint, not a preference.

- **5.4 — Orthogonal but adjacent: ai-meta#188.** The plaintext NATS
  credential (`noetl:noetl`) in Deployment env is a reason to *reduce* the
  NATS trust surface (move to a Secret/keychain, rotate) — it is **not** a
  reason to remove NATS. Handle it on its own track regardless of this RFC.

---

## Appendix — existing swap seams (for whoever implements (a))

- **`CommandSource` trait** (`repos/cli/executor/src/worker/source.rs:154`)
  — `next` / `ack` / `nack`, with `NatsCommandSource` + `MockSource`. The
  clean abstraction on the command-pull path (though EHDB cannot satisfy
  it without a transport — this is where a JetStream-vs-other-bus swap
  would live, not a JetStream-vs-EHDB swap).
- **`EventLogDriver` trait** (`ehdb-reference/src/eventlog.rs:226`) — the
  Phase-10 tunable seam for the store tier; needs a JetStream+Postgres impl
  to stay selectable.
- **`SourceClient`** (`repos/tools/src/tools/source/mod.rs`) and
  **`SpoolBackend`** (`repos/tools/src/spool/backend.rs:41`) — tool/spool
  paths, already multi-impl.
- **Concrete, not yet trait-backed:** server write-path `NatsPublisher`,
  `EventStreamPublisher`, `CoherenceKv`. These need an interface introduced
  before their tiers become driver-selectable.

---

## Related

- `ehdb-wiki/RFC-Server-EHDB-Coupling-and-Storage-Substrate.md` — the
  decided loose-coupling + tunable-substrate shape this RFC stress-tests
  against the transport roles.
- `ehdb-wiki/Design-Event-Log-Core-Engine.md` — Phase 6 store engine +
  the `EventLogDriver` contract.
- `repos/docs/docs/architecture/sharded_state_builder.md` — treats NATS as
  the routing seam and object-store/EHDB as the storage substrate; the
  clearest existing statement of Option (a).
- Issues: ehdb#241, ehdb#254, ai-meta#178, ai-meta#166, ai-meta#116,
  ai-meta#130, ai-meta#156, ai-meta#188.
