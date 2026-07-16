# RFC: EHDB Takeover of NATS — Master Plan + Gap List

**Status:** RFC — design + build plan. DESIGN ONLY, no code lands from this
document.
**Decision context:** Two decisions are settled. **(1) EHDB takes over from
NATS.** **(2) Transport approach (§5.1, locked 2026-07-15): noetl-server-owned
push, reusing the gateway's SSE `ConnectionHub`.** **(3) Topology (§2, locked
2026-07-15): (b) co-locate, not merge** — EHDB durable storage stays in the
**per-shard writer / system pool** (the #166 sharded stateful writers with
affinity); the **noetl-server stays stateless** and owns **delivery only** —
it tails the writer's durable-log change-feed and pushes to workers over the
SSE hub. Option (a) "server embeds EHDB / becomes stateful" is **rejected**
(§2.1). This document is the *how* for the chosen shape and the honest list of
*what is not yet built*.
**Date:** 2026-07-15.
**Builds on:** [`nats-vs-ehdb-transport-boundary.md`](./nats-vs-ehdb-transport-boundary.md).
**Prior art:** `ehdb-wiki/RFC-Server-EHDB-Coupling-and-Storage-Substrate.md`,
`ehdb-wiki/Design-Event-Log-Core-Engine.md`,
`ehdb-wiki/Design-{Projection,KV-Object-Vector}-*.md`,
`ehdb-wiki/Roadmap.md` (Phases 6–10),
`repos/docs/docs/architecture/sharded_state_builder.md`.
**Program tracker:** noetl/ai-meta#194.
**Issues:** ehdb#241 (completion program), ehdb#254 (durable event-log),
ai-meta#178 (query interface), ai-meta#166 (command sharding), ai-meta#116
(affinity), ai-meta#115 (stateless edge), ai-meta#130 (append-notify),
ai-meta#188 (plaintext NATS cred).

---

## 0. The one-paragraph reality

EHDB already covers — or is building, as disabled-by-default shadows — every
**storage** role NATS plays (durable event log via ehdb#254 durable segments,
KV coherence, object/blob, vector, plus projections). What is unbuilt is the
**transport**: real-time worker wakeup, consumer-group work distribution,
ack/redelivery, live subject routing for sharding/affinity, the KEDA lag
signal, and the gateway event feed. The **locked topology** places these
across three components without making EHDB a broker and without making the
server stateful:

- **The per-shard writer** (stateful, system pool, #166 affinity) owns the
  EHDB durable log, does the append, and exposes a bounded **change-feed /
  watch** primitive over it.
- **The noetl-server** (stateless, #115 edge) **tails** that change-feed and
  owns **delivery** — consumer-group assignment, ack, ack_wait redelivery —
  fanning out to workers over the SSE `ConnectionHub` the gateway already
  runs.
- **The worker** becomes an **SSE push client** of the server instead of a
  NATS pull consumer.

This removes NATS, keeps the server **stateless** (the #115 property), reuses
the **per-shard stateful writers #166 already built** for single-writer
ordering, and adds only one new EHDB primitive: a networked change-feed over
the #254 segment log. It is a smaller build than a standalone broker (§5).

---

## 1. THE GAP LIST — what NoETL needs internally that EHDB does not cover

Transport roles (the real gaps) first; storage roles (built/in-flight) last.
"Covered by" names, under the locked topology, which component provides it.

| # | Capability NoETL depends on | Where NoETL uses it (code) | EHDB today | Covered by (locked topology) |
|---|---|---|---|---|
| **G1** | **Real-time wakeup** (worker learns of a command in ~ms) | server `handlers/execute.rs:1679` `js.publish`; worker `nats/subscriber.rs:277` blocking pull | **None.** `tail` is a stateless pull; empty ⇒ `pending_count:0` (`durable_eventlog.rs:1055`). No push/watch/notify (grep = 0). | **Server tails the writer's change-feed → pushes over SSE** (`ConnectionHub`). |
| **G2** | **Consumer-group distribution** (one message → one pool member) | worker `nats/subscriber.rs:252` shared `durable_name`; ai-meta#166 Phase 5 | **None.** Single-cursor replay; N subscribers all see the same records. | **noetl-server** assigns each tailed notification to one subscribed worker per shard (in-memory in-flight table). |
| **G3** | **Ack + redelivery + ack_wait** (at-least-once wakeup) | worker `worker.rs:437-583`; `subscriber.rs:318-350` | **Partial.** `ack` moves a cursor; no visibility timeout, no auto-redelivery, no NAK. | **noetl-server**: the existing HTTP `claim_command` **is** the ack; an ack_wait timer re-pushes an unclaimed notification; `Nak`+delay = affinity steering. |
| **G4** | **Live subject routing** (`noetl.commands.system.shard.<n>.<eid>`, subtree of `…system.>`, + subsumption invariant) | server `sharding.rs:241-254`, `:228-234` | **Filter-for-replay only** (`ehdb-stream` `SubjectFilter`), not live routing. | **Per-shard**: the writer's change-feed is already per-shard (#166); the server tails one feed per shard and keys SSE subscriptions by shard. |
| **G5** | **Backpressure / autoscaling signal** (KEDA on JetStream `num_pending` at `:8222`) | 5× `type: nats-jetstream` ScaledObjects; worker `lag_poller.rs`, `metrics.rs:491` | **None.** | **noetl-server** exports per-shard change-feed-cursor-lag vs claims as a Prometheus gauge; KEDA `type: prometheus` (VictoriaMetrics + GMP already scrape). |
| **G6** | **Gateway → SPA event feed** (SSE fed by `noetl.events.>`) | gateway `sse.rs:88` + `connection_hub.rs:121`, fed by `playbook_state.rs:14` | **None.** | **noetl-server** fans lifecycle events (already riding the same change-feed it tails) to the gateway/SPA. |
| **G7** | **Networked change-feed / watch over the durable log** (so the *stateless server* — a separate process — is woken on append instead of polling) | today the server/worker learn of new work via NATS push, not by reading storage | **None.** `tail` is poll-only, "without a background subscription loop" (`Roadmap.md:531`); EHDB is embedded, no networked watch. | **EHDB, exposed by the per-shard writer**: an in-process append-notify over the #254 segment log, surfaced as a **bounded, per-shard, read-only `Watch(shard, cursor)` server-stream** on the writer's existing data-plane port. Redelivery/groups/ack stay in the server, **not** here. |
| **G8** | **HA / no SPOF** | 1-replica NATS (`nats.yaml:47`) — no HA now | Consensus/replication deferred (`Architecture.md:961`). | **Inherited on two axes:** command delivery HA rides the stateless server (many replicas) + the durable DB command queue; **writer/log HA** is the #166 single-writer-per-shard + the EHDB durable-log replication (S-track, deferred). |
| — | Request/reply · no-responders · heartbeats · leader election | **Not used** — claim + heartbeat are HTTP (`control_plane.rs:366`, `:839`). | n/a | **No gap.** |
| S1 | Durable event **log** store (`noetl_events`) | server `event_publisher.rs:140` | **Built (shadow).** ehdb#254 durable segments; Phase 6 parity. | **EHDB in the per-shard writer** — primary-serve cutover + prod disk format. |
| S2 | Projection / read-model store | worker `materializer.rs` | **Built — primary-serve merged** (Phase 9 tier 2, off). | **EHDB** — prod cutover only. |
| S3 | KV coherence (`chain_heads`, `exec_descriptors`, `subscription_circuit`) | server `coherence.rs:65`; worker `spool_runtime.rs` | **Built (shadow).** Phase 8 `KvStateDriver`. | **EHDB** — primary-serve; coherence-KV-writer question (§2.6). |
| S4 | Object / blob spool | tools `spool/backend.rs:170` | **Built (shadow).** Phase 8 `ObjectBlobDriver`. | **EHDB** — primary-serve. |
| S5 | Vector / RAG | worker `src/ehdb/rag.rs` | **Built (shadow), in-process.** Phase 8 `VectorDriver`. | **EHDB** — primary-serve. |

**One line:** G1–G6 land in the **noetl-server delivery layer**; the only new
**EHDB** primitive is G7 — a **networked per-shard change-feed** the writer
exposes over the #254 log; G8 is inherited (stateless server + DB queue +
#166 single-writer); S1–S5 are built shadows needing gated cutovers.

---

## 2. THE TAKEOVER DESIGN (locked topology: (b) co-locate, not merge)

### 2.1 The three-component split — and why (a) is rejected

```
  worker step completes ──emit event(HTTP)──►  PER-SHARD WRITER  (STATEFUL, system pool, #166 affinity)
                                               ├─ owns the EHDB durable log shard (#254)
                                               ├─ single writer per shard  ⇒  ordered append
                                               ├─ drive/state-builder issues the next command (append)
                                               └─ exposes  Watch(shard, cursor) ──► change-feed stream
                                                                     │
                          (network tail, read-only, per shard)       ▼
                                               NOETL-SERVER  (STATELESS edge, #115)
                                               ├─ tails the writer's change-feed
                                               ├─ consumer-group assignment (1 notification → 1 worker)
                                               ├─ in-flight table + ack_wait redelivery + NAK steering
                                               └─ push over SSE ConnectionHub
                                                                     │
                          (server→worker SSE push, keyed by shard)   ▼
                                               WORKER  (SSE push client; was a NATS pull consumer)
                                               └─ claims the full command over the existing HTTP claim
```

| Component | State | Owns |
|---|---|---|
| **Per-shard writer** (system pool) | **Stateful** (#166) | EHDB durable log shard + append + the change-feed/`Watch` primitive; single-writer ordering per shard by affinity |
| **noetl-server** | **Stateless** (#115) | Delivery only: tail the change-feed, consumer-group assignment, ack, ack_wait redelivery, SSE fan-out |
| **worker** | Stateless compute | An SSE push subscription (replaces the NATS pull consumer) + the existing HTTP claim |

**REJECTED — (a) server embeds EHDB / becomes stateful.** One-line rationale:
it breaks the stateless-edge property from ai-meta#115 and **re-builds storage
the per-shard writers #166 already own** — the writer is the natural home of
the durable log because it already holds single-writer-per-shard affinity and
the drive state. The server stays a stateless delivery edge; storage stays in
the writer. (Also rejected earlier, §2.1-note: a standalone `ehdb-server`
broker — it would re-implement JetStream from zero.)

### 2.2 Command dispatch (G1–G4) — server tails, server fans out

1. **The per-shard writer owns the shard's durable log** and, via the
   off-server drive (#115/#116/#166), appends the events and the
   `command.issued` notification for executions it owns. One writer per shard
   ⇒ the append order **is** the per-execution order — no distributed lock
   (the #116 single-owner ordering, unchanged).
2. **The writer exposes `Watch(shard, cursor) → stream<Record>`** (§2.3) — a
   bounded, read-only, per-shard change-feed on its existing data-plane port.
3. **The stateless server tails** the change-feed for each shard it fronts.
   On a new `command.issued` it pushes a lightweight `Delivery{event_id,
   shard, …}` to **one** subscribed worker for that shard (G2 assignment;
   round-robin / least-in-flight) and records it in an in-flight table.
4. **The worker claims** the full command over the existing HTTP
   `claim_command(event_id)` (`control_plane.rs:366`) — unchanged. A claim
   (or `409 AlreadyClaimed`) is the **ack** (G3): the server clears the
   in-flight entry.
5. **Redelivery** (G3): an ack_wait timer re-pushes an unclaimed in-flight
   entry to another worker; `Nak(delay)` for affinity steering (#166 Phase 4);
   unlimited re-push = `max_deliver=-1` parity.
6. **Recovery:** the DB command queue + the durable log are the truth. A
   server-replica crash → SSE clients reconnect to another replica, which
   resumes tailing from the durable change-feed cursor and re-scans unclaimed
   commands. A writer crash → #166 affinity reassigns the shard; the new owner
   cold-loads the durable log and resumes the change-feed. No wakeup is lost
   because the transport holds no durable state — the writer's log + the DB do.

The server never embeds the EHDB engine; it is a **network client of the
writer's change-feed**, exactly as it is a client of the worker's `:9090`
query relay today. Stateless-edge preserved.

### 2.3 The change-feed / watch primitive (G7) — the one new EHDB part

The per-shard writer already holds the EHDB engine in-process and appends to
its #254 segment log. The change-feed is built from two pieces:

- **In-process append-notify.** On append commit, signal a
  `tokio::sync::Notify` / per-stream `broadcast` keyed by `(shard,
  subject-prefix)`. This generalizes the ai-meta#130 append-notify already
  proven for the WAL index ("the index under the mutex is the source of
  truth; the signal is a liveness hint"). Sub-ms commit→wake **inside the
  writer process**.
- **Networked `Watch(shard, cursor)` server-stream.** Because the *stateless
  server* (a separate process) is the tailer, the notify must cross the
  process boundary. The writer exposes a bounded, read-only server-stream on
  its existing data-plane port: given a durable cursor, it streams committed
  records after it, waking on the in-process notify, re-arming the stream.
  Catch-up (cursor behind head) drains via the existing `tail`/`scan_global`
  then follows the notify — uniform "catch-up then live." Cursor resume on
  reconnect is the #254 durable-cursor property (the old #163 cursor-survives-
  reconnect, now storage-local to the writer).

**What the change-feed does NOT do:** no consumer-group assignment, no ack, no
redelivery, no in-flight tracking — those live in the noetl-server (§2.4). The
writer's `Watch` is a plain ordered record stream after a cursor. This keeps
the EHDB delta minimal: **append-notify + a bounded per-shard `Watch`
server-stream over the #254 log.** No broker, no consensus, no groups in EHDB.

### 2.4 Consumer groups + ack/redelivery live in the stateless server (G2, G3)

The in-flight table, one-notification-to-one-member assignment, ack_wait
timer, and NAK live in the noetl-server (§2.2 steps 3–5) — the same logic a
broker would hold, hosted in the stateless edge that already owns affinity
routing and the DB command queue. The **ack is the existing HTTP claim** — no
new ack protocol. This state is **ephemeral and rebuildable** (from the
durable change-feed cursor + the DB command queue on reconnect), so the server
stays stateless in the #115 sense — it holds no *durable* state, only live
connection + in-flight bookkeeping that any replica can reconstruct.

### 2.5 The lag signal (G5)

The server knows, per shard, its change-feed cursor position vs the claims it
has confirmed — i.e. how many notifications are pending/unclaimed. Export it as
a Prometheus gauge (`noetl_command_shard_pending{shard}`). VictoriaMetrics +
GMP already scrape the cluster, so a KEDA **`type: prometheus`** ScaledObject
replaces `type: nats-jetstream`. The worker's existing lag-gauge shape
(`metrics.rs:491`) is the template.

### 2.6 Control/data-plane — preserved by the split

- The **server never embeds EHDB** and holds no durable state — it is a
  network **client** of the writer's read-only change-feed (like the existing
  `:9090` query relay), and a delivery edge. Stateless-edge (#115) intact.
- The **durable log + change-feed live in the data-plane writer** (system
  pool) — a data-plane role owning data-plane storage, exactly what the
  coupling-RFC boundary intends.
- **Command authorship** stays with the off-server drive in the writer/system
  pool (the #115/#116/#166 model) + the server's `/api/events` gatekeeping —
  unchanged. The physical append is the data-plane writer's job; the server
  gatekeeps *what* enters and *delivers* what is committed.

Residual boundary item unchanged: **who writes coherence KV** (S3) is an
S-track storage question, independent of this transport topology.

### 2.7 Exactly-once + ordering (unchanged)

Exactly-once stays the DB `claim_command` gate. **Per-execution ordering is
the #166 single-writer-per-shard property** — one writer owns a shard, so its
append order is the execution order, the change-feed emits in that order, and
the server pushes in that order. EHDB's global sequence is gapless+monotonic.
Nothing to build; do not regress.

---

## 3. LOAD-BEARING GUARANTEES — met how, and where WEAKER

| Guarantee | NATS today | Locked topology | Weaker than today? |
|---|---|---|---|
| **At-least-once wakeup** | durable consumer, `max_deliver=-1` | server in-flight table + ack_wait re-push + DB/change-feed re-scan (§2.2/2.4) | No once built; N/A until built |
| **Redelivery after worker crash** | ack_wait redelivery | unclaimed in-flight re-pushed after ack_wait | No once built |
| **Redelivery after delivery-edge (server) crash** | JetStream file replay | server holds no durable state; reconnect resumes from the writer's durable change-feed cursor + DB re-scan | **No — arguably stronger** (durable log + DB, not a 1h best-effort stream) |
| **Ordering per execution** | stream seq + subject filter | **#166 single-writer-per-shard** append order → change-feed → push (§2.7) | **Stronger / equal** (single-writer, gapless sequence) |
| **Stateless edge (#115)** | server is already stateless | server holds only ephemeral connection + in-flight state, rebuildable from the durable feed | **Preserved** (the reason (a) was rejected) |
| **Backpressure / autoscaling** | KEDA `nats-jetstream` `:8222` | server per-shard pending gauge + KEDA `prometheus` (§2.5) | No once the scaler swap lands; **BREAKS if command cutover precedes the swap** |
| **Delivery p99 latency** | JetStream push, sub-ms | in-process append-notify (writer) + networked `Watch` tail (server) + SSE push (worker) — 2 hops | **RISK: two process hops (writer→server→worker) vs NATS's one** — the central risk; append-notify + per-shard writer/server co-location keep it bounded; measure on kind before T4 |
| **Cursor-survives-reconnect** | durable consumer by name | #254 durable segment cursor, writer-local (§2.3) | No |
| **Exactly-once execution** | DB claim gate (not NATS) | DB claim gate (unchanged) | No |
| **HA / no SPOF** | 1-replica NATS (no HA now) | delivery: stateless server (N replicas) + DB queue; writer/log: #166 single-writer + EHDB replication (S-track, deferred) | **Not weaker than today; delivery HA is better** |

**Two risks to surface loudly:** (1) **delivery latency** — this topology has
**two process hops** (writer→server→worker) where NATS had one; append-notify
+ keeping the tailing server close to the writer bound it, but it must be
measured on kind before cutover, and it is the reason the p99 budget (§5.4) is
a hard go/no-go. (2) an **autoscaling gap** if the KEDA `prometheus` swap does
not precede the command-bus cutover (§5.3) — a hard sequencing rule.

---

## 4. PHASED MIGRATION — keep prod working throughout

Two tracks, parallel. NATS stays fully resident until the last phase.

### Track S — Storage cutover (independent, proceed now)

Existing Phase 9 per-tier primary cutover; unchanged. Each tier: shadow (done)
→ dual-run parity → `NOETL_EHDB_<TIER>=primary` on kind → GKE, per-tier flag
rollback. S1 event-log needs prod segmented disk format + sharded ordering
aligned with #166. After Track S, NATS carries only transport.

### Track T — Transport build + cutover (co-locate topology)

- **T0 — change-feed → server-tail → SSE-push SHADOW** (spec in §6). The
  per-shard writer exposes the `Watch` change-feed; the server tails one
  shard's feed and pushes to **one** worker over SSE; NATS still authoritative;
  the worker acts on NATS and **compares** the shadow. **No prod change**,
  reversible.
- **T1 — consumer groups + ack_wait + shard routing.** Server-side in-flight
  table, one-to-one assignment across the shard's subscribed workers,
  HTTP-claim-as-ack, ack_wait re-push, `Nak` steering. Validate multi-replica
  distribution + redelivery-on-crash on kind (reuse
  `worker/tests/affinity_multi_replica.rs`).
- **T2 — lag export + KEDA `prometheus` SHADOW.** Server per-shard pending
  gauge; a `prometheus` ScaledObject observe-only beside the live
  `nats-jetstream` one; prove scale decisions match. **Green before T4.**
- **T3 — gateway/SPA feed cutover (G6).** Gateway lifecycle feed off the
  server's change-feed tail instead of `noetl.events.>`. Lowest-risk
  (browser-facing, has the `/api/internal/callback` fallback, `sse.rs:294`).
- **T4 — command-bus cutover (G1–G4).** Workers take commands over the server
  SSE feed; the writer's drive + server delivery replace the NATS publish/pull;
  KEDA switches to `prometheus`. Dual-run **bake** with NATS resident-but-unused
  → flag rollback.
- **T5 — POINT OF NO RETURN: delete the NATS StatefulSet + PVC.** Only after
  T4 bakes clean. Self-sufficiency (k8s-only for platform functionality).

**Point of no return = T5.** Everything through T4 is reversible with NATS
resident. Writer/log multi-node HA is an S-track fast-follow; the transport's
delivery HA is inherited (§2.6/§3) and does not gate T4.

---

## 5. COST, RISK, AND THE OPEN SUB-DECISIONS

### Effort (co-locate topology)

- **Track S:** mostly built; remaining = per-tier primary cutover + S1 prod
  disk format + tunable drivers. **Weeks to a couple months**, in flight.
- **Track T:** **~1.5 quarters.** Less than a standalone broker (1–3q), a
  touch more than a hypothetical "server pushes from its own DB state" because
  the writer must now expose a **networked per-shard `Watch`** the server
  tails (§2.3). Still no new service and no bus-consensus story: it reuses the
  `ConnectionHub` SSE fan-out, the server's affinity, the DB command queue, and
  the #166 per-shard writers; the new code is the writer's `Watch` server-stream
  (append-notify + bounded tail) + the server's tail/assign/ack/redelivery
  delivery layer.
- **T-HA:** EHDB durable-log multi-node replication is a **separate S-track
  effort** (quarters); the transport's delivery HA does not depend on it.

### Biggest risks

1. **Two-hop delivery latency** (writer→server→worker) vs NATS's one hop — the
   central risk; measure on kind before T4 against the §5.4 budget.
2. **Autoscaling gap** if the KEDA swap (T2) does not precede T4 (§5.3).
3. **Server-side redelivery/in-flight correctness** — the same hard logic a
   broker needs, hosted in the stateless server; must survive replica churn by
   rebuilding from the durable change-feed cursor + DB queue.

### Decisions — TWO LOCKED, three still OPEN (for the user)

- **5.1 — Transport approach. ✅ LOCKED (2026-07-15):** noetl-server-owned push
  reusing the gateway SSE `ConnectionHub`; standalone `ehdb-server` broker
  rejected.
- **§2 — Topology. ✅ LOCKED (2026-07-15):** (b) co-locate — durable storage +
  change-feed in the per-shard writer; stateless server owns delivery only.
  Option (a) server-embeds-EHDB rejected (breaks #115 stateless edge; reuses
  #166 writers).
- **5.2 — HA timing. ⬜ OPEN.** For the **EHDB durable log** (S-track): accept
  single-node writer log at S1 primary (parity with today's 1-replica NATS) +
  fund replication as a fast-follow, or gate S1 primary on multi-node
  durability? *A durability posture; not a regression either way.*
- **5.3 — KEDA-before-command-cutover. ⬜ OPEN — HARD RULE.** The `prometheus`
  scaler (T2) must land + validate **before** the command-bus cutover (T4), or
  autoscaling breaks. Confirm it is accepted as a gate.
- **5.4 — Delivery-latency go/no-go budget. ⬜ OPEN — needs a number.** Set the
  acceptable drive-hop **p99** for the two-hop writer→server→worker feed. If
  T0/T1 can't hit it on kind, T4 does not proceed. Name the p99 now so the
  go/no-go is objective.
- **5.5 — ai-meta#188 (adjacent).** The plaintext NATS credential reinforces
  removal; own track; NATS stays resident until T5.

---

## 6. T0 SLICE SPEC — the first buildable step (do NOT build yet)

**Name:** T0 — command/notification feed SHADOW: per-shard writer change-feed →
stateless-server tail → SSE push to one worker, over the EHDB durable log, with
NATS still authoritative.

**Goal / what T0 proves:** the **append → change-feed → server-tail →
SSE-push → worker** path works end-to-end at acceptable latency over the
durable log, **with per-shard ordering preserved**, entirely in the noetl
stack, while **NATS stays fully authoritative** — an observed shadow that
changes no prod behavior and is reversible by a flag.

**Scope (build):**
1. **Writer `Watch` (shadow).** The per-shard writer exposes a bounded,
   read-only `Watch(shard, cursor) → stream<Record>` over its #254 durable log
   (behind `NOETL_SHADOW_WATCH=on`, default off), backed by the in-process
   append-notify. One shard is enough for T0.
2. **Server tail (shadow).** The stateless server tails that one shard's
   change-feed (network client; no EHDB engine embedded) and, on a shadow
   `command.issued`, pushes a `Delivery{event_id, shard}` over SSE to **one**
   subscribed worker — reusing the gateway `ConnectionHub` fan-out.
3. **Worker shadow subscription.** The worker opens a shadow SSE subscription
   (`NOETL_SHADOW_PUSH=on`, default off) **alongside** its live NATS pull. It
   acts on the NATS notification and **records the SSE one for comparison
   only** — it does **not** claim off the shadow feed.
4. **Instrumentation.** Secret-free metrics: writer commit→server-recv latency,
   server→worker SSE push→recv latency, end-to-end append→worker latency,
   per-shard **ordering** check (did shadow deliveries arrive in append order?),
   and shadow-vs-NATS delivery parity per `event_id`.

**Explicitly OUT of T0:** no consumer-group assignment, no ack/redelivery, no
KEDA change, no gateway cutover, no command claimed off the shadow, no NATS
removal, no GKE. All T1+.

**Exit criteria (all on kind, NATS authoritative throughout):**
- **Parity:** for ≥ N drive executions, every command NATS delivered also
  arrived on the SSE shadow feed with a matching `event_id` (0 missed, 0
  spurious).
- **Ordering:** for each execution, shadow deliveries arrived in per-shard
  **append order** (the #166 single-writer property holds end-to-end through
  the change-feed and SSE push) — 0 inversions.
- **Latency:** append→worker p99 (and the two per-hop p99s) captured as
  evidence against the **§5.4 budget** *(placeholder — pending the user's p99
  number; T0 exists to measure it)*.
- **Reconnect / cursor-resume:** kill and reconnect the server's change-feed
  tail; it resumes from the durable #254 cursor with **no missed and no
  duplicated** shadow delivery (a duplicate is acceptable only if it would be
  collapsed by the DB claim gate — record which).
- **Reversibility:** `NOETL_SHADOW_WATCH=off` + `NOETL_SHADOW_PUSH=off` ⇒
  byte-identical `/metrics` and behavior; the worker runs on NATS alone.
- **Boundary:** the server holds SSE connections + its shadow tail cursor
  only — **zero EHDB engine embedding**, zero durable state; the change-feed +
  log stay in the data-plane writer; control-plane guard unviolated.
- **No prod/GKE change; kind-only; rollback = unset the two flags.**

**Hand-off note:** T0 is a `noetl/server` + `noetl/worker` change (writer
`Watch` server-stream in the system-pool worker + server tail/push + worker
shadow SSE subscription), reusing `gateway/src/connection_hub.rs` as the
fan-out template. It opens per-round sub-issues in `noetl/server` and
`noetl/worker` under the umbrella when it goes to build.

---

## 7. What this plan reuses (so it is buildable, not greenfield)

- **#166 per-shard stateful writers + #116 affinity** — already own the durable
  log shard and single-writer ordering; the change-feed hangs off them. **This
  is why (b) co-locate is cheaper than (a) server-embeds.**
- **#115 stateless server edge** — preserved; the server gains a tail + a
  delivery layer, no durable state.
- **gateway `ConnectionHub` SSE** (`connection_hub.rs`, `sse.rs`) — the
  in-house push fan-out the server-owned feed generalizes.
- **DB command queue** — the transport's durable recovery substrate (no bus
  consensus needed).
- **ehdb#254 durable segment log** — the store + the append point the
  change-feed notify hooks.
- **ai-meta#130 append-notify** — the in-process wakeup pattern G7 generalizes.
- **VictoriaMetrics + GMP** — already scraping; KEDA `prometheus` needs no new
  observability infra.
- **The shadow → primary discipline** — every phase copies it.

---

## Related

- [`nats-vs-ehdb-transport-boundary.md`](./nats-vs-ehdb-transport-boundary.md)
  — the code-cited role inventory + capability boundary this builds on.
- `ehdb-wiki/RFC-Server-EHDB-Coupling-and-Storage-Substrate.md` — the
  loose-coupling decisions; §2.6 shows the co-locate split preserves them.
- `ehdb-wiki/Design-Event-Log-Core-Engine.md` and the other Design pages —
  Track S engines.
- `repos/docs/docs/architecture/sharded_state_builder.md` — the #166 per-shard
  stateful-writer + append-notify patterns this topology reuses.
- Program tracker: noetl/ai-meta#194.
- Issues: ehdb#241, ehdb#254, ai-meta#178, ai-meta#166, ai-meta#116,
  ai-meta#115, ai-meta#130, ai-meta#188.
