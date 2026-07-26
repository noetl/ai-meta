# RFC: EHDB Takeover of NATS — Master Plan + Gap List

**Status:** RFC — design + build plan. DESIGN ONLY, no code lands from this
document.
**Decision context:** The keep-or-replace question is **settled — EHDB takes
over from NATS.** The transport approach is **also settled (§5.1, locked
2026-07-15): noetl-server-owned push, reusing the gateway's SSE
`ConnectionHub`, over EHDB's durable log + change-feed primitives.** A
standalone `ehdb-server` stream broker is the **rejected** alternative
(§2.1). This document is the *how* for the chosen approach, and the honest
list of *what is not yet built*.
**Date:** 2026-07-15.
**Builds on:** [`nats-vs-ehdb-transport-boundary.md`](./nats-vs-ehdb-transport-boundary.md)
(the role inventory + capability boundary this reuses).
**Prior art:** `ehdb-wiki/RFC-Server-EHDB-Coupling-and-Storage-Substrate.md`,
`ehdb-wiki/Design-Event-Log-Core-Engine.md`,
`ehdb-wiki/Design-{Projection,KV-Object-Vector}-*.md`,
`ehdb-wiki/Roadmap.md` (Phases 6–10),
`repos/docs/docs/architecture/sharded_state_builder.md`.
**Program tracker:** noetl/ai-meta#194 (this program's umbrella).
**Issues:** ehdb#241 (completion program), ehdb#254 (durable event-log),
ai-meta#178 (query interface), ai-meta#166 (command sharding), ai-meta#116
(affinity), ai-meta#130 (append-notify), ai-meta#188 (plaintext NATS cred).

---

## 0. The one-paragraph reality

EHDB already covers — or is building, as disabled-by-default shadows — every
**storage** role NATS plays (durable event log via ehdb#254 durable segments,
KV coherence, object/blob, vector, plus projections). What is unbuilt is the
**transport**: real-time worker wakeup, consumer-group work distribution,
ack/redelivery, live subject routing for sharding/affinity, the KEDA lag
signal, and the gateway event feed. The **locked approach** builds that
transport in the **noetl stack, not inside EHDB**: EHDB grows a
**change-feed / watch primitive over its durable log** so consumers stop
polling; the **noetl-server owns delivery** — it pushes command
notifications and lifecycle events to workers and the SPA over the SSE
fan-out the gateway already runs (`connection_hub.rs`), and owns
consumer-group assignment, ack, and redelivery. This choice removes NATS
**and** — because the command transport lives in the server (which is already
the event gatekeeper) while the durable log stays a data-plane worker
concern — it **dissolves the control-plane/data-plane write problem** that a
shared broker would have created (§2.6). The result is a smaller build than a
standalone broker (§5), reusing three things already in production: the
server's execution-affinity, the DB command queue, and the gateway's SSE hub.

---

## 1. THE GAP LIST — what NoETL needs internally that EHDB does not cover

Transport roles (the real gaps) first; storage roles (built/in-flight) last.
The "Covered by" column names, under the locked approach, whether EHDB or the
noetl-server provides it.

| # | Capability NoETL depends on | Where NoETL uses it (code) | EHDB today | Covered by (locked approach) |
|---|---|---|---|---|
| **G1** | **Real-time wakeup** (worker learns of a command in ~ms) | server `handlers/execute.rs:1679` `js.publish`; worker `nats/subscriber.rs:277` blocking pull | **None.** `tail` is a stateless pull; empty ⇒ `pending_count:0` (`durable_eventlog.rs:1055`). No push/watch/notify (grep = 0). Embedded, no service. | **noetl-server** pushes over SSE (reuses gateway `ConnectionHub`); the server is the command author, so it needs no EHDB read to know there is work. |
| **G2** | **Consumer-group distribution** (one message → one pool member) | worker `nats/subscriber.rs:252` shared `durable_name`; ai-meta#166 Phase 5 | **None.** Single-cursor replay; N subscribers all see the same records. | **noetl-server** assigns each notification to one subscribed worker per shard (in-memory in-flight table, DB-backed). |
| **G3** | **Ack + redelivery + ack_wait** (at-least-once wakeup) | worker `worker.rs:437-583`; `subscriber.rs:318-350` | **Partial.** `ack` moves a cursor; no visibility timeout, no auto-redelivery, no NAK. | **noetl-server**: the existing HTTP `claim_command` **is** the ack; an ack_wait timer re-pushes an unclaimed notification to another worker; `Nak`+delay = affinity steering. |
| **G4** | **Live subject routing** (`noetl.commands.system.shard.<n>.<eid>`, subtree of `…system.>`, + subsumption invariant) | server `sharding.rs:241-254`, `:228-234` | **Filter-for-replay only** (`ehdb-stream` `SubjectFilter`), not live routing. | **noetl-server** keeps the exact shard scheme as the SSE subscription key (`subscribe(shard=n)`); assignment honors the same subsumption fallback. |
| **G5** | **Backpressure / autoscaling signal** (KEDA on JetStream `num_pending` at `:8222`) | 5× `type: nats-jetstream` ScaledObjects; worker `lag_poller.rs`, `metrics.rs:491` | **None.** | **noetl-server** exports per-shard unclaimed/in-flight as a Prometheus gauge (VictoriaMetrics + GMP already scrape); KEDA `type: prometheus` replaces `nats-jetstream`. |
| **G6** | **Gateway → SPA event feed** (SSE fed by `noetl.events.>`) | gateway `sse.rs:88` + `connection_hub.rs:121`, fed by `playbook_state.rs:14` | **None.** | **noetl-server** fans lifecycle events to the gateway/SPA (every event already flows through the server's `POST /api/events` write path — no NATS, no EHDB read needed). |
| **G7** | **Change-feed / watch over the durable log** (so the co-located drain consumers — materializer, projector, state-builder — stop polling) | worker `materializer.rs`, `state_builder.rs:1176`, server 3× durable consumers on `noetl_events` | **None** — `tail` is poll-only, "without a background subscription loop" (`Roadmap.md:531`). | **EHDB**: an **in-process append-notify** over the #254 segment log wakes the co-located drains on commit (they run *inside* the worker/system-pool where EHDB is embedded — no network needed). Optional networked watch only if a drain ever moves cross-process. |
| **G8** | **HA / no SPOF** | 1-replica NATS (`nats.yaml:47`) — no HA now | Consensus/replication deferred (`Architecture.md:961`). | **Largely inherited:** command transport HA rides the server's existing execution-affinity + the durable DB command queue (a dead replica re-routes; unclaimed commands recover from the DB). EHDB durable-log HA is a separate S-track concern. |
| — | Request/reply · no-responders · heartbeats · leader election | **Not used** — claim + heartbeat are HTTP (`control_plane.rs:366`, `:839`); no NATS RPC/leader election found. | n/a | **No gap.** |
| S1 | Durable event **log** store (`noetl_events`) | server `event_publisher.rs:140` | **Built (shadow).** ehdb#254 durable segments; Phase 6 parity. | **EHDB** — primary-serve cutover + prod disk format. |
| S2 | Projection / read-model store | worker `materializer.rs` | **Built — primary-serve merged** (Phase 9 tier 2, off). | **EHDB** — prod cutover only. |
| S3 | KV coherence (`chain_heads`, `exec_descriptors`, `subscription_circuit`) | server `coherence.rs:65`; worker `spool_runtime.rs` | **Built (shadow).** Phase 8 `KvStateDriver`. | **EHDB** — primary-serve; resolve who writes coherence KV (§2.6). |
| S4 | Object / blob spool | tools `spool/backend.rs:170` | **Built (shadow).** Phase 8 `ObjectBlobDriver`. | **EHDB** — primary-serve. |
| S5 | Vector / RAG | worker `src/ehdb/rag.rs` | **Built (shadow), in-process.** Phase 8 `VectorDriver`. | **EHDB** — primary-serve. |

**One line:** G1–G6 are unbuilt and land in the **noetl-server**; G7 (the only
new EHDB primitive) is an **in-process append-notify** over the #254 log; G8
is largely inherited from server affinity + the DB; S1–S5 are built shadows
needing gated cutovers.

---

## 2. THE TAKEOVER DESIGN (locked approach)

Storage (S1–S5) uses the existing shadow → primary machinery (§4 Track S).
This section designs the transport under the locked split: **EHDB provides a
change-feed; the noetl-server provides delivery.**

### 2.1 Split of responsibilities — and why the broker is rejected

| Concern | Owner | Mechanism |
|---|---|---|
| Durable log + ordering + retention | **EHDB** (data-plane, embedded in worker/system-pool) | #254 durable segments, gapless global sequence, `KeepAll` |
| Change-feed / watch (stop polling) | **EHDB** | in-process append-notify over the segment log (G7) |
| Command wakeup + fan-out | **noetl-server** | SSE push to workers via the `ConnectionHub` pattern (G1) |
| Consumer-group assignment | **noetl-server** | per-shard in-flight table, one-notification-to-one-member (G2) |
| Ack / redelivery / NAK | **noetl-server** | HTTP `claim_command` = ack; ack_wait re-push; NAK+delay steering (G3) |
| Live subject routing | **noetl-server** | shard = SSE subscription key; subsumption fallback (G4) |
| Lag signal | **noetl-server** | per-shard pending gauge → KEDA `prometheus` (G5) |
| Gateway/SPA feed | **noetl-server** | lifecycle fan-out off the `/api/events` write path (G6) |

**REJECTED — standalone `ehdb-server` stream broker.** Rationale (one line):
it would re-implement JetStream's client-facing semantics (server-streaming
Subscribe, consumer groups, ack_wait, a monitoring endpoint, and its own
consensus story) as a **new deployed service from zero** — a multi-quarter
build — when the noetl-server + gateway SSE hub + DB command queue already
provide the delivery substrate. Do not relitigate; if the server-owned path
proves inadequate on latency (§5.5), the broker returns as the fallback, not
the default.

### 2.2 Command dispatch (G1–G4) — server-owned, EHDB not in the path

The server already authors commands (writes `command.issued` + the DB command
row). It does not need to read EHDB to know there is work — it just created
it. So the wakeup is a pure noetl-stack push:

1. **Worker subscribes** to the server for its shard(s): a long-lived
   server→worker SSE (or gRPC server-stream) keyed by
   `noetl.commands.system.shard.<n>` — the exact #166 scheme, now a
   subscription key instead of a NATS subject. This reuses the gateway's
   `ConnectionHub` (`connection_hub.rs:121`, per-client `mpsc::UnboundedSender`)
   generalized from browser clients to worker clients.
2. **On command creation** the owning server replica (execution-affinity, #116)
   pushes a lightweight `Delivery{event_id, shard, ...}` to **one** subscribed
   worker for that shard (G2 assignment; round-robin / least-in-flight), and
   records it in an in-flight table.
3. **The worker claims** the full command over the existing HTTP
   `claim_command(event_id)` (`control_plane.rs:366`) — unchanged. A successful
   claim is the **ack** (G3): the server clears the in-flight entry. `409
   AlreadyClaimed` also clears it (a duplicate push collapsed by the DB claim
   gate).
4. **Redelivery** (G3): an ack_wait timer (default 30 s) re-pushes any
   in-flight entry that was never claimed to another worker; `Nak(delay)` for
   affinity steering (#166 Phase 4). Unlimited re-push = `max_deliver=-1`
   parity.
5. **Recovery** after a server-replica crash: the DB command queue is the
   durable truth; the re-routed affinity owner re-scans unclaimed commands and
   re-pushes. No wakeup is lost because the DB — not the transport — is the
   source of truth (today's `noetl_commands` is already best-effort/1h).

Latency: an in-memory push over an already-open SSE connection — comparable to
NATS push, no poll interval, no EHDB read.

### 2.3 The EHDB change-feed / watch primitive (G7) — the only new EHDB part

The **drain consumers** (materializer, projector, state-builder,
result/state materializers) fold the durable event log. They run **inside the
worker/system-pool process, where EHDB is embedded** — so the change-feed is
in-process, not networked:

- **Append-notify.** When the event-log engine commits an append to the #254
  segment log, it signals a `tokio::sync::Notify` / per-stream `broadcast`
  keyed by `(stream, subject-prefix)`. A drain task parked on that key wakes
  on commit and drains via the existing `tail`/`scan_global` — **no poll
  interval.** This generalizes the ai-meta#130 append-notify already proven
  for the WAL index ("the index under the mutex is the source of truth"; the
  signal is a liveness hint) — the sharded-state-builder RFC §6.3 already
  relies on this shape.
- **Durable cursor + resume.** Each drain keeps its durable per-consumer
  cursor (already in #254); a restart resumes from the cursor then follows the
  notify — uniform "catch-up then live," no special case (G7 / the old #163
  cursor-survives-reconnect property, now purely storage-local).
- **No networked watch needed for the drains** because they are co-located
  with the engine. A networked watch RPC is deferred and only revisited if a
  drain ever moves to a separate process — which the current architecture does
  not require.

This is the whole EHDB-side delta for the transport: **an in-process
append-notify + a resumable durable cursor over the #254 log.** No broker, no
new service, no consensus.

### 2.4 Consumer groups + ack/redelivery live in the server (G2, G3)

Because delivery is server-owned, the in-flight table, group assignment,
ack_wait timer, and NAK all live in the noetl-server (§2.2 steps 2–4) — the
same logic a broker would hold, but hosted in the service that already owns
affinity and the DB command queue. The **ack is the existing HTTP claim** —
no new ack protocol. Crash semantics: a worker crash → its in-flight entries
never claim → ack_wait re-pushes; a server-replica crash → affinity re-route +
DB re-scan. At-least-once wakeup holds; the DB claim gate collapses
duplicates (exactly-once execution, unchanged).

### 2.5 The lag signal (G5)

The server already knows, per shard, how many commands are unclaimed
(in-flight table + a bounded DB query on the command queue). Export it as a
Prometheus gauge (e.g. `noetl_command_shard_pending{shard}`). VictoriaMetrics
+ GMP already scrape the cluster, so a KEDA **`type: prometheus`** ScaledObject
reads it in place of `type: nats-jetstream`. The worker's existing lag-gauge
shape (`metrics.rs:491`) is the template.

### 2.6 Control/data-plane — resolved by the split, not deferred

A standalone broker would have forced the stateless server to read/write an
EHDB data-plane stream — breaching coupling-RFC Decision 1. The locked split
**avoids it entirely**:

- The **command transport carries no EHDB access** — the server pushes from
  its own DB-backed command state; EHDB is not in the command path.
- The **EHDB change-feed is consumed only by co-located data-plane drains**
  (worker/system-pool) — a data-plane read by a data-plane role, exactly what
  the boundary permits.
- The **server never reads or writes EHDB** for transport. It stays the
  control-plane gatekeeper of *what* enters the log (via `/api/events`), while
  the physical append is the data-plane worker's job (the Phase 6 model,
  unchanged).

Residual boundary item: **who writes coherence KV** (S3 `chain_heads` /
`exec_descriptors`), which the *server* writes today. That is an S-track
storage question (keep on a control-plane store vs move to EHDB), unchanged by
this transport decision and tracked separately.

### 2.7 Exactly-once + ordering (unchanged, not the transport's job)

Exactly-once stays the DB `claim_command` gate; per-execution ordering stays
server affinity + `ChainHeads`; EHDB's global sequence is gapless+monotonic
(if anything stronger than JetStream). Nothing to build; do not regress.

---

## 3. LOAD-BEARING GUARANTEES — met how, and where WEAKER

| Guarantee | NATS today | Locked design | Weaker than today? |
|---|---|---|---|
| **At-least-once wakeup** | durable consumer, `max_deliver=-1` | server in-flight table + ack_wait re-push + DB re-scan (§2.2/2.4) | No once built; N/A until built |
| **Redelivery after worker crash** | ack_wait redelivery | unclaimed in-flight re-pushed after ack_wait | No once built |
| **Redelivery after transport-owner crash** | JetStream file replay | DB command queue is durable truth; affinity re-route + re-scan | **No — arguably stronger** (DB-backed, not a 1h best-effort stream) |
| **Ordering per execution** | stream seq + subject filter | gapless monotonic global sequence + affinity | **Stronger** |
| **Backpressure / autoscaling** | KEDA `nats-jetstream` `:8222` | server per-shard pending gauge + KEDA `prometheus` (§2.5) | No once the scaler swap lands; **BREAKS if command cutover precedes the swap** |
| **Delivery p99 latency** | JetStream push, sub-ms | in-memory SSE push over an open connection (§2.2) | **RISK: parity depends on the SSE feed staying push, not degrading to reconnect/poll** — the central risk; measure on kind before T4 |
| **Change-feed for drains (no poll)** | JetStream push consumer | in-process append-notify over #254 (§2.3) | No — in-process notify is faster than a network consumer |
| **Cursor-survives-reconnect** | durable consumer by name | durable segment cursor, storage-local (§2.3) | No |
| **Request-reply / no-responders / heartbeats** | not used / HTTP | unchanged | N/A |
| **Exactly-once execution** | DB claim gate (not NATS) | DB claim gate (unchanged) | No |
| **HA / no SPOF** | 1-replica NATS (no HA now) | inherited: server affinity + DB command queue; EHDB-log HA is S-track (deferred) | **Not weaker than today; transport HA is actually better** (DB-backed) |

**Two risks to surface loudly:** (1) **delivery latency** if the server→worker
SSE feed degrades to reconnect/poll under churn — measure on kind before
cutover; (2) an **autoscaling gap** if the KEDA `prometheus` swap does not
precede the command-bus cutover — a hard sequencing rule (§5.4), not a
preference.

---

## 4. PHASED MIGRATION — keep prod working throughout

Two tracks, parallel. NATS stays fully resident until the last phase.

### Track S — Storage cutover (independent, proceed now)

Existing Phase 9 per-tier primary cutover; unchanged by this RFC. Each tier:
shadow (done) → dual-run parity → `NOETL_EHDB_<TIER>=primary` on kind → GKE,
per-tier flag rollback.

- **S1 Event log** (`NOETL_EHDB_EVENTLOG`) — needs prod segmented disk format +
  sharded ordering aligned with #166 first.
- **S2 Projection** — primary-serve merged; prod cutover only.
- **S3 KV / S4 Object / S5 Vector** — primary-serve; S3 resolves the
  coherence-KV-writer question (§2.6).

After Track S, NATS carries **only** transport (G1–G7). That is the
prerequisite for Track T's command cutover.

### Track T — Transport build + cutover (server-owned-push variant)

- **T0 — command/lifecycle feed SHADOW** (spec in §6). Generalize the gateway
  `ConnectionHub` to a server→worker SSE feed + EHDB in-process append-notify
  for the drains; the server **dual-notifies** (NATS authoritative + SSE
  shadow); a canary worker compares. **No prod change**, reversible.
- **T1 — consumer groups + ack_wait + shard routing.** In-flight table, one-to-one
  assignment, HTTP-claim-as-ack, ack_wait re-push, `Nak` steering; shard =
  subscription key. Validate multi-replica distribution + redelivery-on-crash
  on kind (reuse `worker/tests/affinity_multi_replica.rs` shape).
- **T2 — lag export + KEDA `prometheus` SHADOW.** Server per-shard pending
  gauge; a `prometheus` ScaledObject observe-only beside the live
  `nats-jetstream` one; prove scale decisions match. **Green before T4.**
- **T3 — gateway/SPA feed cutover (G6).** Gateway lifecycle feed off the
  server push instead of `noetl.events.>`. Lowest-risk (browser-facing, has
  the `/api/internal/callback` fallback, `sse.rs:294`).
- **T4 — command-bus cutover (G1–G4).** Workers take commands over the server
  SSE feed; server stops publishing to NATS; KEDA switches to the `prometheus`
  scaler. Dual-run **bake** with NATS resident-but-unused → flag rollback.
- **T5 — POINT OF NO RETURN: delete the NATS StatefulSet + PVC.** Only after
  T4 bakes clean. Self-sufficiency (k8s-only for platform functionality).

**Point of no return = T5.** Everything through T4 is reversible with NATS
resident. T-HA (multi-node EHDB durable log) is an S-track fast-follow; the
transport's HA is inherited (§2.6/§3) and does not gate T4.

---

## 5. COST, RISK, AND THE OPEN SUB-DECISIONS

### Effort (revised for the server-owned-push variant)

- **Track S:** mostly built; remaining = per-tier primary cutover + S1 prod
  disk format + tunable drivers. **Weeks to a couple months**, in flight.
- **Track T:** **materially less than a standalone broker.** No new service,
  no bus consensus story — it reuses the `ConnectionHub` SSE fan-out, the
  server's affinity, and the DB command queue; the only new EHDB primitive is
  an in-process append-notify (a generalization of #130). Realistic estimate
  **~1–1.5 quarters** (vs 1–3 for the rejected broker), dominated by getting
  the in-flight/redelivery/latency right under load and the KEDA swap.
- **T-HA:** EHDB durable-log multi-node replication is a **separate S-track
  effort** (quarters); the transport does not depend on it.

### Biggest risks

1. **SSE feed latency/stability under churn** — the drive hot path must stay
   push, not degrade to reconnect/poll. Measure on kind before T4 (§5.5).
2. **Autoscaling gap** if the KEDA swap (T2) does not precede T4 (§5.4).
3. **Underestimating server-side redelivery/in-flight correctness** — it is
   the same hard logic a broker needs, just hosted in the server.

### Decisions — one LOCKED, three still OPEN (for the user)

- **5.1 — Transport approach. ✅ LOCKED (2026-07-15):** noetl-server-owned
  push over EHDB's durable log + change-feed, reusing the gateway SSE
  `ConnectionHub`. Standalone `ehdb-server` broker rejected (§2.1).
- **5.2 — HA timing. ⬜ OPEN.** Transport HA is inherited (DB + affinity), so
  this narrows to the **EHDB durable-log** S-track: accept single-node EHDB
  log at S1 primary (parity with today's 1-replica NATS store) and fund
  replication as a fast-follow, or gate S1 primary on multi-node durability?
  *Needs a call; not a regression either way, but it is a durability posture.*
- **5.3 — KEDA-before-command-cutover sequencing. ⬜ OPEN — HARD RULE.** The
  `prometheus` scaler (T2) must land and validate **before** the command-bus
  cutover (T4), or autoscaling breaks at cutover. This is an ordering
  **constraint**, not a preference — confirm it is accepted as a gate.
- **5.4 — Delivery-latency go/no-go budget. ⬜ OPEN — needs a number.** Set the
  acceptable drive-hop **p99** for the SSE feed. If T0/T1 can't hit it on
  kind, T4 does not proceed and the broker fallback is reconsidered. Name the
  p99 target now so the go/no-go is objective.
- **5.5 — ai-meta#188 (adjacent).** The plaintext NATS credential reinforces
  removing NATS but rides its own track; NATS stays resident until T5.

---

## 6. T0 SLICE SPEC — the first buildable step (do NOT build yet)

**Name:** T0 — command/lifecycle notification feed, SHADOW over EHDB durable
log via the SSE hub.

**Goal / what T0 proves:** the **append → notify → push** path works
end-to-end at acceptable latency, entirely in the noetl stack, with **NATS
still fully authoritative** — i.e. a command notification can travel
server→worker over an SSE feed (backed by the server's command state) and a
lifecycle event can travel worker→server→SPA, while an EHDB in-process
append-notify wakes a co-located drain on commit — all as an **observed
shadow** that changes no prod behavior and is reversible by a flag.

**Scope (build):**
1. **Server→worker SSE feed (shadow).** Generalize the gateway
   `ConnectionHub` (`connection_hub.rs`) into a server-side per-worker SSE
   registry keyed by `shard`. Workers open a shadow subscription
   (`NOETL_SHADOW_PUSH=on`, default off) alongside their live NATS pull.
2. **Shadow dual-notify.** On command creation, the server continues to
   `js.publish` to NATS (authoritative) **and** pushes a shadow `Delivery` over
   SSE. The worker receives both; it acts on the NATS one and **records the
   SSE one for comparison only** (does not claim off the shadow).
3. **EHDB append-notify (shadow).** Wire a `tokio::sync::Notify` on the #254
   event-log append commit (behind `NOETL_EHDB_EVENTLOG` shadow, already
   present) and have one co-located drain wake on it, recording
   notify→drain latency — **without** serving any read from it.
4. **Latency instrumentation.** Secret-free metrics: server-push→worker-recv
   latency, EHDB commit→notify→drain latency, and shadow-vs-NATS delivery
   parity (did the SSE `Delivery` match the NATS notification for the same
   `event_id`?).

**Explicitly OUT of T0:** no consumer-group assignment, no ack/redelivery, no
KEDA change, no gateway cutover, no command claimed off the shadow feed, no
NATS removal, no GKE. All of that is T1+.

**Exit criteria (all on kind, NATS authoritative throughout):**
- **Parity:** for ≥ N drive executions, every command that NATS delivered also
  arrived on the SSE shadow feed with a matching `event_id` (0 missed, 0
  spurious) — the feed is delivery-complete.
- **Latency:** server-push→worker-recv p99 and EHDB commit→notify→drain p99 are
  both **at or below the §5.4 target** the user sets (the number T0 exists to
  measure) — captured as evidence, not asserted.
- **Reversibility:** `NOETL_SHADOW_PUSH=off` ⇒ byte-identical `/metrics` and
  behavior; the worker runs on NATS alone with the shadow removed.
- **Boundary:** the server holds SSE connections + its own command state only;
  it performs **zero EHDB reads/writes**; the EHDB append-notify is consumed by
  a co-located data-plane drain only (control-plane guard unviolated).
- **No prod/GKE change**; kind-only; documented rollback = unset the flag.

**Hand-off note:** T0 is a `worker` + `server` change (SSE feed + shadow
dual-notify + append-notify wiring), reusing `gateway/src/connection_hub.rs`
as the fan-out template. It opens per-round sub-issues in `noetl/server` and
`noetl/worker` under the umbrella when it goes to build.

---

## 7. What this plan reuses (so it is buildable, not greenfield)

- **gateway `ConnectionHub` SSE** (`connection_hub.rs`, `sse.rs`) — the
  in-house push fan-out the server-owned feed generalizes. **This is the load
  reduction vs a broker.**
- **noetl-server execution-affinity (#116) + the DB command queue** — the
  transport's HA and recovery substrate; no new consensus needed for the bus.
- **ehdb#254 durable segment log** — the storage floor + the append point the
  change-feed notify hooks.
- **ai-meta#130 append-notify** — the proven in-process wakeup pattern G7
  generalizes.
- **ai-meta#166 sharding + #116 affinity** — the shard scheme reused as the
  SSE subscription key + assignment fallback.
- **VictoriaMetrics + GMP** — already scraping, so the KEDA `prometheus` swap
  needs no new observability infra.
- **The shadow → primary discipline** (`off|shadow|primary` flags, parity
  harnesses, compile-time guards) — every transport phase copies it.

---

## Related

- [`nats-vs-ehdb-transport-boundary.md`](./nats-vs-ehdb-transport-boundary.md)
  — the role inventory + capability boundary (code-cited) this plan builds on.
- `ehdb-wiki/RFC-Server-EHDB-Coupling-and-Storage-Substrate.md` — the
  loose-coupling decisions; §2.6 shows the locked split preserves them.
- `ehdb-wiki/Design-Event-Log-Core-Engine.md`,
  `Design-Projection-Read-Model-Engine.md`,
  `Design-KV-Object-Vector-Engines-Phase-8.md`, `Roadmap.md` — Track S engines.
- `repos/docs/docs/architecture/sharded_state_builder.md` — the append-notify
  + shard-routing patterns reused.
- Program tracker: noetl/ai-meta#194.
- Issues: ehdb#241, ehdb#254, ai-meta#178, ai-meta#166, ai-meta#116,
  ai-meta#130, ai-meta#188.
