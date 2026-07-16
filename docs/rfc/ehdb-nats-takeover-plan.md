# RFC: EHDB Takeover of NATS — Master Plan + Gap List

**Status:** RFC — design + build plan. DESIGN ONLY, no code lands from this
document.
**Decisions settled:** **(1) EHDB takes over from NATS.** **(2) Transport =
noetl-server-controlled, EHDB-backed push (§5.1).** **(3) Topology (§2, locked
2026-07-15): (c) per-shard-writer-as-broker** — the stateful per-shard writer
(system pool) owns its shard's durable log **and** delivery (change-feed,
consumer-group, ack, push); **workers subscribe directly to their shard's
writer**; the **stateless server** publishes the next command to the writer
and is **out of the delivery path**. Delivery is **one hop** (writer→worker),
matching NATS. Superseded/rejected topologies are in the ledger (§2.1).
**Date:** 2026-07-15.
**Builds on:** [`nats-vs-ehdb-transport-boundary.md`](./nats-vs-ehdb-transport-boundary.md).
**Program tracker:** noetl/ai-meta#194.
**Issues:** ehdb#241, ehdb#254, ai-meta#178, ai-meta#166 (command sharding —
**dormant in prod, see §2.2**), ai-meta#116 (affinity), ai-meta#115 (stateless
edge / off-server drive), ai-meta#130 (append-notify), ai-meta#163 (system-pool
OOM), ai-meta#188.

---

## 0. The one-paragraph reality (read this first — the premise was corrected)

A code trace of the live command cycle corrected two assumptions behind
earlier drafts, and they shape everything below:

1. **The off-server inter-step cycle is 6 message hops today**, server-relayed
   throughout: `step-worker →(HTTP)→ server →(NATS)→ system-worker →(HTTP)→
   server →(NATS)→ step-worker`. The two worker pools **never talk directly**;
   the server is a mandatory relay on every hop (`execute.rs:1680` is the
   *only* command-publish site; the system-pool drive worker hands its result
   **back to the server** via `POST /api/events`, and the server publishes the
   next command — `events.rs:3811 → 3357 → execute.rs:1680`).
2. **#166 per-shard sharding is dormant in prod.** The system pool is a single
   **`Deployment`, `replicas: 1`** (`worker-system-pool-deployment-prod.yaml:25,36`),
   **no StatefulSet, no PVC, no per-shard deployments, no per-pod identity**,
   and `NOETL_SHARD_INDEX`/`NOETL_SHARD_COUNT` are unset → affinity inert. No
   worker addresses a specific pod anywhere; all pod-to-pod traffic is NATS +
   the load-balanced server Service.

So (c) is **not** a cheap "relocate delivery onto the writers #166 already
built" — those stateful, addressable, connection-terminating per-shard writers
**do not exist yet**. (c) is sound and worth adopting (§2.3), but it is a
**build**, not a relocation, and it is **more work than the superseded (b)**,
not less — justified because it is the only shape that gets NATS-parity
one-hop delivery *and* a stable per-shard fan-out point (§2.4). This RFC states
that honestly rather than forcing the earlier framing.

---

## 1. THE GAP LIST — what NoETL needs internally that EHDB does not cover

Transport roles (the real gaps) first; storage roles (built/in-flight) last.

| # | Capability | Where NoETL uses it (code) | EHDB today | Covered by (topology (c)) |
|---|---|---|---|---|
| **G1** | **Real-time wakeup** (worker learns of a command in ~ms) | server `execute.rs:1680` `js.publish`; worker `nats/subscriber.rs:277` pull | **None** (no push/watch/notify; grep=0). | **Per-shard writer pushes to the worker** over a direct subscription (one hop). |
| **G2** | **Consumer-group distribution** (one message → one pool member) | worker `subscriber.rs:252` shared durable consumer | **None.** | **Per-shard writer** assigns each command to one subscribed worker. |
| **G3** | **Ack + redelivery + ack_wait** | worker `worker.rs:437`; `subscriber.rs:318` | **Partial** (cursor advance, no timeout/redelivery/NAK). | **Per-shard writer**: HTTP `claim_command` = ack; ack_wait re-push; NAK steering. |
| **G4** | **Shard routing / affinity** | server `sharding.rs:241`; **dormant** | Filter-for-replay only. | **Intrinsic**: the writer *is* the shard; a worker subscribes to the writer that owns its execution's shard. |
| **G5** | **Backpressure / autoscaling signal** | 5× `nats-jetstream` ScaledObjects; worker `metrics.rs:491` | **None.** | **Per-shard writer** exports its pending/in-flight as a Prometheus gauge; KEDA `prometheus` (VM+GMP already scrape). |
| **G6** | **Gateway → SPA event feed** (SSE fed by `noetl.events.>`) | gateway `sse.rs:88`, `playbook_state.rs:14` **subscribes NATS** | **None** — and note the gateway's cross-pod fan-out *is* NATS today. | Gateway subscribes to the writers' change-feeds (or the server relays lifecycle events it already receives at `/api/events`). |
| **G7** | **Change-feed / watch over the durable log** | today workers/gateway learn via NATS push | **None** (`tail` poll-only, `Roadmap.md:531`). | **EHDB, in the writer**: in-process append-notify over #254 + the writer's own push loop (no separate network watch — the writer is co-located with the log it serves). |
| **G8** | **Stable per-shard fan-out point + HA** | NATS: 1 stable broker pod (`nats.yaml:47`, **1 replica**) | Deferred. | **Per-shard writer** as a stable addressable pod (needs StatefulSet + PVC + identity — **new, §2.5**). |
| **G9** | **Worker↔broker discovery** (find + reconnect to the broker) | `NATS_URL` / `NOETL_SERVER_URL` = load-balanced Service DNS | n/a | **New**: workers must resolve + connect to the *specific* shard writer (StatefulSet stable DNS) — **no analogue today (§2.5)**. |
| — | Request/reply · no-responders · heartbeats · leader election | Not used (HTTP). | n/a | **No gap.** |
| S1–S5 | Durable log / projection / KV / object / vector **store** | (Track S) | **Built shadows**; projection primary merged. | **EHDB in the per-shard writer** — gated primary cutovers. |

**One line:** delivery (G1–G5, G7) lands **in the per-shard writer**; G8/G9
(stable per-shard identity + worker discovery) are **net-new infrastructure**
that does not exist today; S1–S5 are built shadows needing gated cutovers.

---

## 2. THE TAKEOVER DESIGN (topology (c): per-shard-writer-as-broker)

### 2.1 Alternatives ledger (so the progression is legible)

| Option | Shape | Verdict |
|---|---|---|
| **(a)** standalone `ehdb-server` broker | one new networked service brokers all shards | **REJECTED — monolith.** Re-implements JetStream centrally; reintroduces a single broker (SPOF like NATS) + a new service from zero. |
| **(b)** storage/delivery split | writer owns log+change-feed; **stateless server tails it** and delivers | **SUPERSEDED — latency.** Two delivery hops (writer→server→worker); the server-tail added a hop for no delivery benefit. |
| **(b′)** server-direct-push | server pushes the command it already computes, straight to the worker | **SET ASIDE — cross-replica fan-out.** One hop *in principle*, but the server is multi-replica and stateless with **no stable identity**; "push to worker W" needs to reach the replica holding W's connection — exactly the fan-out a broker provides. A stateless fleet cannot be a stable fan-out point. |
| **(c)** per-shard-writer-as-broker | the **stateful** per-shard writer owns log + delivery; workers subscribe to it; server publishes to it | **ADOPTED.** One hop (writer→worker); the writer is the **stable addressable fan-out point** the stateless server can't be; distributed (not a monolith); server stays stateless. Cost: it's a build, not a relocation (§2.5). |

The load-bearing insight (b′ surfaced, c resolves): **delivery needs a stable,
addressable fan-out point per shard.** NATS was that point. A stateless,
horizontally-fungible server fleet (#115) cannot be. The **stateful per-shard
writer** can — which is why delivery belongs on the writer, not the server.

### 2.2 The hop validation — is (c) genuinely one delivery hop?

**Yes, at the per-command delivery level, and it can collapse the whole
cycle.** Today (offserver, code-traced):

```
step-worker ─HTTP─► server ─NATS─► system-worker ─HTTP─► server ─NATS─► step-worker
     completion         __orchestrate__        call.done(result)      next command
   H1            H2            H3          H4/H5          H6           H7   (+HTTP claims H4,H8)
                                   = 6 message hops (8 with claims)
```

The server relays every hop; the drive worker and the step worker never touch.

Under (c), the per-shard writer owns store **and** drive **and** delivery, so
the server exits the inter-step loop:

```
step-worker ─► shard-writer(store+drive+deliver) ─► step-worker
   completion            (in-process)               next command
        = ~2 hops; delivery (writer→worker) = ONE hop, matching NATS
```

- **Per-command delivery** (the latency the worker feels): `writer → worker`,
  **one hop** — identical to today's `NATS → worker`. This is the fix for
  (b)'s two-hop regression. ✓
- **Full inter-step cycle:** if the writer also drives (it already builds the
  state — `state_builder.rs`), the 6-hop server round-trip collapses to ~2.
  That is a *bigger* win than "one delivery hop," but it means **moving
  orchestration off the server into the writer** — today the server drives
  (`events.rs` `apply_orchestration_result`) and the writer only builds state.
  Treat the full collapse as the end-state; the first cut can keep the server
  computing "next" and *publishing to the writer* (still one delivery hop).

**No hidden extra hop, with one caveat:** today the pushed message is a
*pointer* and the worker does an HTTP `claim_command` round-trip to fetch the
body (`control_plane.rs:369`). (c) can carry the **full command** in the
writer's push (it owns the log + the command), eliminating the claim
round-trip — but that moves the exactly-once gate off the DB `claim_command`,
so keep the claim gate initially and treat body-in-push as a T1+ optimization.

### 2.3 The component split

```
  server (STATELESS, #115)                         PER-SHARD WRITER (STATEFUL, system pool)
  ├─ kicks off executions                          ├─ owns the EHDB durable log shard (#254) + PVC
  ├─ publishes the initial (and, first cut,        ├─ single writer per shard ⇒ ordered append
  │   each next) command TO the owning writer  ──► ├─ (end-state) drives: builds state + computes next
  └─ never in the delivery path                    ├─ change-feed = in-process append-notify (#130)
                                                    ├─ consumer-group assignment + ack_wait + NAK
                                                    └─ pushes to subscribed workers  ──┐
                                                                                        │ ONE hop
   worker (SSE/stream push client) ◄────────────────────────────────────────────────┘
   └─ claims/acks; executes; emits completion back to the owning writer
```

| Component | State | Owns |
|---|---|---|
| **Per-shard writer** (system pool) | **Stateful** | Durable log shard + delivery (change-feed, group assignment, ack/redelivery, push); (end-state) the drive |
| **noetl-server** | **Stateless** (#115) | Kick-off + publish-to-writer; **not** in the delivery path; holds no durable state |
| **worker** | Stateless compute | A direct push subscription to its shard's writer + claim/ack; emits completion to the writer |

### 2.4 Preserved invariants

- **#115 stateless server:** the server embeds no EHDB, holds no durable state,
  and is out of the delivery path — it publishes to the writer (like it
  publishes to NATS today) and stays horizontally fungible. **Preserved — more
  cleanly than (b)** (no change-feed tail state on the server).
- **#166 per-shard ordering:** one writer per shard is the sole appender **and**
  the sole deliverer for its shard, so append order = delivery order per
  execution. **Preserved / strengthened** (same pod owns order and push).
- **Data/control-plane boundary:** the durable log + delivery live in the
  data-plane writer (system pool); the control-plane server never reads/writes
  EHDB. **Preserved.**

### 2.5 The honest downsides — spelled out, not glossed

1. **The writer now terminates worker subscriptions** — a stateful pod serving
   many long-lived client connections. **Cost:** the system pool is the
   memory-pressured pod (ai-meta#163 OOM'd it 768Mi→2Gi under the WAL index
   alone). Adding N worker connections + a push loop + (end-state) the drive
   concentrates three heavy jobs on that pod. It already runs an axum server on
   `:9090` (metrics/query), so the serving machinery exists, but sizing/QoS
   needs real headroom. **Not fatal; a real sizing risk.**
2. **Per-shard HA is unbuilt — and today there is none.** The system pool is
   `Deployment, replicas: 1`, no failover; a pod death **stalls the drive**
   until k8s reschedules (correctness held by the reconcile poller +
   cold-rebuild, `events.rs:2500`, `:3716`). The **HA posture is decided
   (§2.6, LOCKED): shards-only now, per-shard replication deferred** — a writer
   is a StatefulSet+PVC single owner per shard (parity with today's
   single-replica NATS), with a bounded loss-free failover stall; multi-replica
   HA is a named, later, non-blocking phase. See §2.6 for the parity check, the
   replication-ready seam, and the failover/stall estimate.
3. **Worker↔writer discovery is net-new** (G9). Today no worker addresses a
   specific pod; everything is load-balanced Service DNS. (c) needs workers to
   resolve `shard_for(execution_id)` → the **specific** writer's StatefulSet
   DNS, and reconnect on failover/rebalance. StatefulSet stable identity gives
   the addressing, but the worker-side resolve/connect/reconnect layer has **no
   analogue in the codebase** and must be built.
4. **Connection fan-out grows with shard count.** A step worker executes steps
   for executions across **many** shards, so it must connect to **many** shard
   writers (up to S). NATS avoided this — one connection, subject-filtered. (c)
   trades that for `S`-connections-per-worker; at 2 shards negligible, at 16
   (the point of sharding is to grow S) it is a real connection-management +
   discovery burden, and adding a shard makes every worker discover + connect a
   new writer. **This is the genuinely new cost NATS's single-broker model did
   not have.** Mitigation options (shard-partition the step pool; or a
   subset-subscription policy) are T1+ design, not free.
5. **EHDB moves from library toward service** — each per-shard writer now
   terminates connections and serves a push protocol. But it is **distributed
   per-shard, not a monolith** (contrast (a)), and rides the writer's existing
   `:9090` server, so it is an extension, not new standalone infra. Still, "the
   storage engine now runs a client-facing push server" is a real scope-shift
   to acknowledge.

**Verdict: (c) is sound and not fatally flawed — adopt it.** It uniquely
delivers one-hop latency *and* a stable per-shard fan-out point, keeps the
server stateless, and shrinks the blast radius vs today's single NATS. But it
is a **build** (StatefulSet + PVC + identity + worker↔writer channel +
discovery + the delivery stack in the writer + moving publish/drive off the
server), **more work than (b)**, and it carries a real connection-fan-out cost
that scales with shard count and a real concentration risk on the OOM-prone
system pod.

### 2.6 HA posture — shards-only now, replication-ready, RF deferred (LOCKED 2026-07-15)

**Decision:** ship (c) **shards-only** — one writer per shard, no per-shard
replicas — and defer per-shard **replication factor (RF)** to a named,
post-cutover HA phase (§4 T-RF). The NATS takeover **completes at shards-only
parity** (NATS deleted at T5); RF is hardening *beyond* parity, not a blocker.

**Parity check (verified against the manifests, read-only):** prod NATS is
`kind: StatefulSet … replicas: 1` (`ops/ci/manifests/nats/nats.yaml:56`),
single-node JetStream (`store_dir /data/jetstream`, file store, no cluster
peers), and the command/event streams set **no `num_replicas`** override
(`server/src/nats/publisher.rs` / `event_publisher.rs` use default Config) → a
1-node JetStream cannot host R>1 anyway, so streams are **R1**. (A
`nats-supercluster/` manifest set exists — cluster-a/cluster-b — but it is the
separate multi-region variant, **not** the deployed baseline.) So **prod NATS
delivery has no HA today**; single-writer-per-shard is **parity, not
regression**. If a future prod moves NATS to a clustered R3, revisit — but as
deployed, the claim holds.

**Replication-READY seam (the hard requirement — additive-only, no rewrite
later).** The #254 durable log is already shaped for replication; T0–T4 must
build on these primitives (not a pod-local-only shortcut) so RF is purely
additive:

- **Immutable append + shippable segments.** `DurableSegmentStore` writes
  append-only CRC-framed segments (`seg-<id>.eslog`) with `fsync` + a bounded
  offset index and O(1) open via a `StoreCheckpoint` sidecar
  (`durable_eventlog.rs`). Segments are immutable once written ⇒ byte-for-byte
  **shippable and replayable** to a follower with no format change.
- **Single-writer + read-only followers already modeled.**
  `durable_eventlog_affinity.rs` enforces "at most one replica writes"; a
  non-owner does `open_read_only`. The leader/follower distinction thus exists
  at the storage layer **today** — a runtime lock, **not** a format assumption
  of "exactly one writer forever."
- **Log-shipping contract already exists.** `durable_eventlog_shared.rs` has
  the owner publish new segment bytes to a shared store and a non-owner
  cold-load + replay them. That is log replication to a shared medium, already
  built (for cold-load failover).
- **Cursors are durable + external.** The global-sequence cursor and the
  consumer-ack cursor persist in the transaction log / checkpoint sidecar
  (cross-process), so they are **derivable by any promoted follower**, not
  owned by a single process's memory.

The one **new discipline (c) must observe** for RF-readiness at the *delivery*
layer: the consumer-group **in-flight / ack state must stay derivable** from
(durable cursor + DB `claim_command` state), never the sole source of truth in
the leader's memory. Then a promoted follower reconstructs it (at-least-once;
the DB claim gate collapses any redelivery). Bake this in at T1.

**What a future RF phase ADDS vs. REWRITES:**

| RF adds (additive) | Must NOT rewrite (already RF-shaped) |
|---|---|
| **Hot followers** — continuously tail the shared-store log (vs cold-load only on failover) to stay caught up | Segment format, CRC framing, offset index, `StoreCheckpoint` |
| **Leader election** — promote a follower on leader failure (Raft, or a lease/lock over the shared store); the affinity single-writer lock already gates *who* writes | The single-writer invariant + `open_read_only` follower path |
| **Replicated delivery in-flight/ack** (optional) — so unacked in-flight survives promotion without redelivery | The global-sequence + consumer-ack durable cursors |
| A per-shard leader-selecting Service (or keep the same StatefulSet DNS pointing at the leader) | Worker discovery (stable shard DNS is unchanged across RF) |

Net: RF adds *hot-follow + election (+ optional delivery-state replication)*
and rewrites **nothing** in the log/cursor/shipping layer, provided T0–T4 use
the `durable_segment` + shared-tier primitives above.

**Failover story (shards-only, the accepted downtime mode until RF):**

1. Shard-N writer pod dies.
2. The StatefulSet controller reschedules `…-shard-N-0` (**same** stable
   identity + DNS).
3. Its per-shard **PVC reattaches** (StatefulSet `volumeClaimTemplate` → same
   volume) — the #254 log is intact (loss-free).
4. The writer opens the log **O(1)** via the `StoreCheckpoint` sidecar
   (ai-meta#267) + replays only the bounded tail — not the whole history.
5. It rebuilds delivery in-flight state from the durable cursor + the DB
   unclaimed-command set.
6. Workers re-dial the **unchanged** shard DNS (backoff) and resume from their
   durable cursor.

**Stall estimate:** dominated by k8s pod reschedule (typically single-digit to
low-tens of seconds, image cached / `imagePullPolicy` permitting) + PVC
reattach (seconds); the replay is O(1)-open + bounded tail (ai-meta#267 +
the #166 cold-load lineage), **not** O(history). Net: a **bounded,
loss-free, single-shard (1/N-of-traffic) stall on the order of seconds** —
the same class as a NATS pod restart today, but scoped to one shard instead of
all delivery. This is the **accepted downtime mode until T-RF lands.**

---

## 3. LOAD-BEARING GUARANTEES — met how, and where WEAKER

| Guarantee | NATS today | Topology (c) | Weaker than today? |
|---|---|---|---|
| **At-least-once wakeup** | durable consumer, `max_deliver=-1` | writer in-flight table + ack_wait re-push; DB claim gate | No once built |
| **Redelivery after worker crash** | ack_wait redelivery | writer ack_wait re-push to another subscriber | No once built |
| **Redelivery after broker crash** | JetStream file replay (1 replica) | writer PVC durable log survives; reschedule + cold-load; **one shard, not all** | **No — smaller blast radius** |
| **Ordering per execution** | stream seq + subject | #166 single-writer-per-shard = sole appender **and** deliverer | **Stronger / equal** |
| **Stateless edge (#115)** | already stateless | server publishes + kicks off; not in delivery; no durable state | **Preserved (cleaner than (b))** |
| **Delivery p99 latency** | JetStream push, 1 hop | writer→worker, **1 hop** (fixes (b)'s 2-hop); inter-step cycle can collapse 6→2 | **Parity; potentially better** |
| **Backpressure / autoscaling** | KEDA `nats-jetstream` | writer per-shard pending gauge + KEDA `prometheus` | No once the swap lands; **breaks if it lags the cutover** |
| **Cursor-survives-reconnect** | durable consumer by name | #254 durable cursor, writer-local (needs PVC) | No |
| **Exactly-once execution** | DB claim gate (not NATS) | DB claim gate (unchanged) | No |
| **Broker availability / failover** | 1-replica NATS (verified `nats.yaml:56`), restart-recovery, **no HA** | 1-writer-per-shard StatefulSet+PVC, loss-free bounded-stall failover (§2.6); **RF deferred** | **Parity (both single-owner restart-recovery); (c) smaller blast radius (1/N); RF phase later exceeds NATS** |
| **Single-broker connection simplicity** | 1 worker connection, subject-filtered | **S connections per worker** (fan-out) | **WEAKER — the real cost of distributing the broker (§2.5.4)** |

**Risks to surface loudly:** (1) **connection fan-out** (S per worker, grows
with shards) — the one place (c) is genuinely weaker than NATS; (2)
**concentration on the OOM-prone system pod** (#163); (3) **autoscaling gap**
if the KEDA swap lags the cutover; (4) (c) needs **new StatefulSet+PVC+identity
+ discovery** infra to reach even today's restart-recovery parity — that infra
is the bulk of the build.

---

## 4. PHASED MIGRATION

### Track S — storage cutover (independent, proceed now)

Existing Phase 9 per-tier `shadow → primary`, reversible by flag, kind before
GKE. **S1 event-log additionally needs the system pool converted to a
StatefulSet + PVC** (the durable log must survive restarts) — this is shared
prerequisite work with Track T. After Track S, NATS carries only transport.

### Track T — transport build + cutover (topology (c))

- **T0 — direct writer→worker delivery SHADOW** (spec §6). Stand up ONE
  per-shard writer as a StatefulSet pod exposing a push subscription; a worker
  subscribes directly and receives a shadow command over one hop; NATS still
  authoritative; **latency-vs-NATS measured as a first-class output.**
- **T1 — writer delivery stack:** consumer-group assignment + ack_wait
  redelivery + NAK steering + worker↔writer discovery/reconnect + the
  connection-fan-out policy. Validate multi-writer distribution + failover on
  kind.
- **T2 — lag export + KEDA `prometheus` SHADOW** beside the live
  `nats-jetstream` scaler; prove parity. **Green before T4.**
- **T3 — gateway/SPA feed cutover** off `noetl.events.>`.
- **T4 — command-bus cutover:** workers take commands from the writers; server
  publishes to the writers; KEDA on `prometheus`; dual-run bake with NATS
  resident.
- **T5 — POINT OF NO RETURN:** delete the NATS StatefulSet + PVC. **The
  takeover completes here, at shards-only parity.**
- **T-RF (deferred HA phase, post-cutover, NON-BLOCKING):** add per-shard
  **replication factor** — hot followers (continuous shared-store tail) +
  leader election + optional replicated delivery in-flight state (§2.6). Turns
  the seconds-stall failover into sub-second/seamless promotion, exceeding
  today's NATS availability. **Additive on the §2.6 seam — no log/cursor
  rewrite. Cost: quarters** (the consensus/election build is the biggest,
  riskiest piece — the reason it is deferred, not folded into the cutover).
- **T-drive (optional, end-state):** move the drive fully into the writer to
  collapse the 6→2 inter-step cycle. Not required to remove NATS; a latency
  follow-on.

Everything through T4 reversible with NATS resident. T5 is the PONR; **T-RF and
T-drive are post-takeover hardening, explicitly not gating T5.**

---

## 5. COST, RISK, DECISIONS

### Effort (topology (c))

- **Track S:** mostly built; + the StatefulSet/PVC conversion of the system
  pool (shared with T). Weeks to a couple months.
- **Track T: ~2 quarters** — **more than the superseded (b)** (~1.5q), because
  (c) adds net-new infra (per-shard StatefulSet + PVC + stable identity), the
  worker↔writer discovery/connection layer (no analogue today), and the
  connection-fan-out policy — on top of the same delivery stack (change-feed,
  group, ack, push) (b) needed, now hosted in the writer. It **buys** the
  one-hop latency (b) couldn't and the drive-collapse potential.
- **T-RF / T-drive:** separate post-takeover follow-ons (quarters each); the
  per-shard replication build (T-RF) is deliberately **outside** the ~2q cutover
  estimate — folding consensus in would blow it (§2.6).

### Biggest risks

1. **Connection fan-out** scaling with shard count (§2.5.4) — the one genuine
   regression vs NATS; needs a subscription policy.
2. **Concentration on the #163 OOM-prone system pod** (log + drive + N
   connections + push loop).
3. **Latency:** one hop *in principle*, but a stateful writer under memory
   pressure serving many connections could still miss the budget — measure at
   T0 (§5.4).
4. **Autoscaling gap** if the KEDA swap lags T4 (§5.3).

### Decisions — FOUR LOCKED, two OPEN

- **5.1 — Transport = server-controlled, EHDB-backed push. ✅ LOCKED.**
- **§2 — Topology = (c) per-shard-writer-as-broker. ✅ LOCKED (2026-07-15).**
  (a) rejected-as-monolith; (b) superseded-on-latency; (b′) set-aside
  (cross-replica fan-out).
- **§2.6 — HA posture = shards-only now, RF deferred. ✅ LOCKED (2026-07-15).**
  Ship (c) single-writer-per-shard (parity with prod's verified 1-replica
  NATS), loss-free bounded-stall failover via StatefulSet+PVC; per-shard
  replication factor is the named, non-blocking **T-RF** phase. **Requirement
  carried into the build:** T0–T4 use the #254 `durable_segment` + shared-tier
  primitives so RF is additive (§2.6 seam), and the delivery in-flight/ack
  state stays derivable from the durable cursor + DB claim gate.
- **5.3 — KEDA-before-command-cutover. ⬜ OPEN — HARD RULE.** T2 must validate
  before T4 or autoscaling breaks.
- **5.4 — Delivery-latency go/no-go budget. ⬜ OPEN — needs a number.** Set the
  drive-hop **p99**; T0 measures the real writer→worker hop vs NATS and it is a
  go/no-go for T4.
- **5.5 — Connection-fan-out policy (NEW open item). ⬜ OPEN.** Decide before
  T1: do step workers connect to all S shard writers, or is the step pool
  shard-partitioned (bigger change), or a subset policy? This bounds how (c)
  scales with shard count.
- **5.6 — ai-meta#188 (adjacent).** Plaintext NATS cred; own track; NATS
  resident until T5.

---

## 6. T0 SLICE SPEC — the first buildable step (do NOT build yet)

**Name:** T0 — direct per-shard-writer → worker delivery SHADOW, over the EHDB
durable log, with NATS still authoritative, and a **latency-vs-NATS
comparison** as a first-class output.

**Goal / what T0 proves:** a worker can subscribe **directly** to one shard's
writer and receive a command over a **single hop** (writer→worker) at
acceptable latency, with per-shard ordering preserved and cursor-resume on
reconnect against the #254 durable cursor — while **NATS stays fully
authoritative** (shadow only, reversible, kind-only).

**Scope (build):**
1. **One writer-as-broker pod (shadow).** Stand up a single system-pool writer
   as a StatefulSet pod (PVC-backed #254 log) exposing a bounded push
   subscription (server-stream over its existing `:9090` axum server), fed by
   the in-process append-notify (#130) on append commit. One shard.
2. **Direct worker subscription (shadow).** A worker resolves that one shard
   writer's stable DNS and opens a shadow push subscription
   (`NOETL_SHADOW_DIRECT_SUB=on`, default off) **alongside** its live NATS pull.
   It acts on the NATS command and **records the direct-push one for comparison
   only** (does not claim off the shadow).
3. **Latency comparison (first-class).** Emit, per command, both the
   NATS-deliver timestamp and the direct-writer-push timestamp for the same
   `event_id`, so T0 yields the **real writer→worker hop cost vs NATS** — the
   number §5.4 needs.
4. **Instrumentation.** Secret-free metrics: writer commit→worker-recv p99
   (direct) vs NATS-recv p99; per-shard **ordering** check; parity per
   `event_id`.

**Explicitly OUT of T0:** no consumer-group assignment, no ack/redelivery, no
multi-shard fan-out, no discovery layer beyond one hard-wired shard, no KEDA,
no gateway cutover, no command claimed off the shadow, no NATS removal, no GKE.
All T1+.

**Exit criteria (all on kind, NATS authoritative throughout):**
- **Parity:** every command NATS delivered also arrived on the direct shadow
  push with a matching `event_id` (0 missed, 0 spurious).
- **Ordering:** direct deliveries arrived in per-shard **append order** (#166
  single-writer property holds through the writer's push) — 0 inversions.
- **Latency:** direct writer→worker p99 captured **and compared head-to-head
  against the NATS→worker p99 on the same drives** — the deliverable that
  answers "is one-hop-via-writer really NATS-parity?" (go/no-go against §5.4).
- **Reconnect / cursor-resume:** kill + reconnect the worker's direct
  subscription; it resumes from the #254 durable cursor with no missed / no
  duplicated shadow delivery (duplicate acceptable only if the DB claim gate
  would collapse it).
- **Reversibility:** `NOETL_SHADOW_DIRECT_SUB=off` ⇒ byte-identical `/metrics`
  + behavior; worker on NATS alone.
- **Boundary:** the server is **not** involved in the shadow delivery path; the
  writer serves it from its co-located log; the server embeds no EHDB.
- **No prod/GKE change; kind-only; rollback = unset the flag.**

**Hand-off note:** T0 is a `noetl/worker` change (writer push server-stream in
the system-pool worker's `:9090` server + a worker-side direct subscription
client) + an `ops` change (system pool → StatefulSet + PVC + headless Service
for stable DNS). It opens per-round sub-issues under the umbrella at build.

---

## 7. What this plan reuses / what is net-new

**Reused:** the system-pool worker's existing `:9090` axum server (push
endpoint host); the #254 durable segment log (store + append-notify hook) **and
its already-replication-shaped modules** (`durable_eventlog_affinity.rs`
single-writer + `open_read_only` followers; `durable_eventlog_shared.rs`
owner-publish + follower-cold-load log shipping) — the §2.6 seam that makes the
deferred T-RF additive; the ai-meta#130 append-notify pattern; the DB
`claim_command` exactly-once gate; the off-server drive state builder
(`state_builder.rs`); the ai-meta#267 O(1) checkpoint open + #166 cold-load
lineage (bounds the failover replay); VictoriaMetrics + GMP (KEDA `prometheus`
needs no new observability infra); the shadow→primary discipline.

**Net-new (this is the honest bulk of Track T):** the system pool as a
**StatefulSet + PVC + stable per-pod identity** (today a single-replica
Deployment); the **writer's delivery stack** (group assignment, ack_wait,
push loop); the **worker↔writer discovery + connection layer** (no analogue in
the codebase); the **connection-fan-out policy** (§5.5); and moving
command-publish (and, end-state, the drive) off the server into the writer.

---

## Related

- [`nats-vs-ehdb-transport-boundary.md`](./nats-vs-ehdb-transport-boundary.md)
  — the code-cited role inventory + capability boundary.
- `ehdb-wiki/RFC-Server-EHDB-Coupling-and-Storage-Substrate.md`,
  `Design-Event-Log-Core-Engine.md`, `Roadmap.md` — Track S engines.
- `repos/docs/docs/architecture/sharded_state_builder.md` — the #166 per-shard
  stateful-writer + append-notify patterns (note: sharding is **dormant in
  prod** per §2.2; (c) is what would activate + extend it).
- Program tracker: noetl/ai-meta#194.
- Issues: ehdb#241, ehdb#254, ai-meta#178, ai-meta#166, ai-meta#116,
  ai-meta#115, ai-meta#163, ai-meta#130, ai-meta#188.
