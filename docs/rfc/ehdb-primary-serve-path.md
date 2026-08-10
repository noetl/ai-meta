# RFC — EHDB primary serve path: a writer-fronted tier service

**Status:** draft, for review
**Date:** 2026-08-10
**Tracks:** [noetl/ai-meta#247](https://github.com/noetl/ai-meta/issues/247)
**Author:** Claude (session 2026-08-10)

---

## 1. Problem

EHDB's five storage tiers (event-log, projection, KV, object, vector) have a
`primary` mode that is supposed to make EHDB serve authoritatively in place of
the incumbent (JetStream + Postgres). **It does not exist.** Not "is disabled" —
does not exist.

Everything below was measured this session, not inferred.

### 1.1 `serve_primary_cycle` is a diagnostic, not a serve path

Its only caller in the crate is `src/bin/ehdb-selfcheck.rs`. By its own contract
it *"never authors a NoETL event"*: it appends **synthetic** records, reads them
back, then **flips itself to `shadow` and mirrors one more event to prove
rollback**. Wiring it into the runtime would inject fabricated records into the
tier. It is a conformance drive for the fabric, and correct as such.

### 1.2 `primary` used to silently disarm verification

`runtime_hook_env` gated on `!= Shadow`, so `primary` returned `None`: the mirror
stopped and nothing served in its place. Measured in kind, one binary, identical
load:

| `NOETL_EHDB_EVENTLOG` | events mirrored |
| :-- | --: |
| `shadow` | 30 |
| `primary` | **0** |

Fixed in [noetl/worker#251](https://github.com/noetl/worker/pull/251) — all five
tiers now arm the mirror in **both** `shadow` and `primary`; only `off` disarms,
plus a WARN and an `outcome="primary_not_wired"` counter. This RFC builds on that
**monotonic arm**: asking for a stronger mode must never reduce verification.

### 1.3 The tier is not one store — it is N disjoint pod-local stores

- The default backend is `LocalReference`, a **pod-local JSONL** driver.
- Each worker mirrors into **its own** `NOETL_EHDB_LOCAL_REFERENCE_LOG`.
- The server's `/api/ehdb/*` resolves tier data from the **server's own**
  `from_env()` location — not where any worker writes. On prod,
  `/api/ehdb/health` returns **404**.
- Every prod PVC is **ReadWriteOnce** (`premium-rwo`), so the "shared mount"
  that `NOETL_EHDB_EVENTLOG_SHARED_DIR` anticipates cannot be mounted by more
  than one pod.

So a promotion to `primary` today would promote *whichever fragment happens to be
pod-local*, while the incumbent holds all history.

### 1.4 The authoritative log is server-owned

`noetl.event` lives in Postgres and is read/written by the **server**
(`src/db/queries/event.rs`). The server has **no EHDB storage-tier integration** —
only bus integration (`command_bus.rs`, `coherence.rs`) plus the read-only
`/api/ehdb/*` handlers. And per
[`data-access-boundary.md`](../../agents/rules/data-access-boundary.md), workers
must not reach `noetl.*` directly at all.

**Therefore primary is a server-side capability over a shared store — not
something a worker can switch on.** That is the whole reason this needs an RFC
rather than a flag.

---

## 2. What already exists (do not rebuild)

Being explicit, because a surprising amount of the substrate is present:

| piece | state |
| :-- | :-- |
| Tier drivers + parity comparators | **done** — `ehdb_reference`, all five tiers, suites pass on the released image |
| `DurableSegmentStore`, `SharedSegmentBackend`, `ShardOwnership`, `Routed` | **done** — shard ownership and a shared-tier medium are already modelled |
| Segment GC | **done** — `eventlog_gc`, `consumer_ack` policy |
| Shadow mirror on the live path | **done + LIVE in prod**, parity holding |
| A service-hosting pattern | **done** — the writer already fronts both buses (`ehdb_feed::serve_ingest` / `serve_group_claims` / `serve_sse` over bound `TcpListener`s, ports 9100–9108) |
| Server read surface | **partial** — `/api/ehdb/*` exists and resolves tier backends, but against a pod-local location |

**The missing piece is narrow and specific: remote access to a single durable
tier store.** The durable backend assumes a filesystem it can open. Nothing lets
another pod read or append to that store.

---

## 3. Design

### 3.1 Storage model — one durable store, on the writer

Rejected: **shared RWX filesystem.** It needs Filestore, changes the storage
class of a live StatefulSet, and makes concurrent writers a correctness problem
the segment format would have to solve. RWO is also what prod has today.

Chosen: **the writer owns the durable tier store and fronts it as a service.**

This follows the user's decision — *"writer should keep the PVC storage… a
special type of worker for EHDB, similar to how we do system workers"* — and it
is what the writer already is: the same `noetl-worker` binary with
`WORKER_POOL_NAME=cmdbus-writer`, holding the durable volumes, already hosting
two services. Adding a third service to a process built to host services is the
smallest coherent step.

```
   workers (N)                        writer (1, durable PVCs)         server
   ───────────                        ────────────────────────         ──────
   mirror ─────── tier append ──────▶ :9110 tier-service ──▶ segment store
                                                    ▲
   /api/ehdb/*, read paths ────────── tier read ────┘ ◀─────────────── resolver
```

Shard ownership already exists (`ShardOwnership`, `Routed`), so a multi-writer
future is an extension, not a rewrite. Phase 1 is single-owner, matching prod's
`replicas: 1`.

### 3.2 Wire protocol

Mirror the buses rather than invent: **length-framed binary frames over TCP**,
same shape as `serve_ingest` / `read_frame`, on a new port `:9110`
(`NOETL_EHDB_TIER_SERVICE_BIND`), with `:9111` for metrics if warranted.

Operations, one request/response frame each, derived from what the drivers
already do:

| op | direction | notes |
| :-- | :-- | :-- |
| `append(tier, execution_id, payload, opts)` | worker → writer | returns assigned sequence + parity verdict |
| `read(tier, after_seq, limit)` | server → writer | bounded scan |
| `read_execution(tier, execution_id)` | server → writer | per-execution slice |
| `tail(tier)` | server → writer | durable tip |
| `ack(tier, consumer, seq)` | server → writer | drives existing GC |
| `health(tier)` | any → writer | readiness + tip, cheap |

Explicitly **not** in phase 1: streaming/subscribe (the events bus already
covers that), cross-shard routing, and auth beyond the existing internal-token
pattern.

### 3.3 `primary` keeps mirroring — serve **and** verify

Building on worker#251's monotonic arm. In `primary`:

1. the tier append is served by EHDB **and** the incumbent write still happens;
2. the parity comparator runs on every operation, as in shadow;
3. divergence is recorded (`parity_mismatch` / `PrimaryDivergence`) and — this
   is the safety property — **divergence does not fail the caller**, it demotes:
   the incumbent's answer is returned and the tier is marked degraded.

Serving must never be less verified than shadowing. A mode that stops checking
itself the moment it starts being trusted is exactly the defect worker#251 fixed.

### 3.4 Cutover, per tier, with rollback

Per tier, never in bulk:

```
off ──▶ shadow ──▶ (parity holds over a real window) ──▶ primary ──▶ (verify) ──▶ steady
                                     ▲                        │
                                     └──── rollback: flag ────┘
```

Rollback is the flag back to `shadow`. It is safe **because primary only
appends** — it never mutates or deletes what the incumbent owns, and the
incumbent keeps being written throughout (§3.3). This preserves the append-only
`noetl.event` invariant absolutely.

Event-log tier goes **last**, not first: it is the source of truth for replay.
Suggested order: **KV → object → projection → vector → event-log.**

### 3.5 Data-access boundary

Unchanged and reinforced. Workers never read `noetl.*`. The tier service carries
**derived** EHDB fabric data, not the authoritative NoETL tables; the server
remains the only component that reads/writes `noetl.event`. When the event-log
tier eventually goes primary, it is the **server** that resolves through the tier
service — the worker's role stays "mirror + verify".

---

## 4. Acceptance gates

Every phase, no exceptions. These are the session's standing rules, written down
so a later reader cannot treat them as optional:

1. **Behaviour-level, on a RELEASED image in kind** — never a local build, never
   a source-call-site assertion.
2. **Two-sided** — the flag-off half must reproduce the pre-change behaviour, or
   the gate cannot discriminate.
3. **Positive control** — a check that has never produced a positive result is
   indistinguishable from one that cannot.
4. **Mutation-checked**, with a mutation that *compiles*.
5. **Fail loud** — a failed fetch is reported, never coerced to an empty/zero
   that reads as a pass.
6. **Parse with a parser.** No regex against JSON.
7. **Flag-gated, default-off**; land inert; capture rollback before any prod
   change.

---

## 5. PRs

| # | PR | Repo | Risk | Gate |
| :-- | :-- | :-- | :-- | :-- |
| **1** | Tier-service **skeleton + protocol**: frame codec, `serve_tier` listener, `health` + `append` ops, bind flag default-**unset** (no listener unless set) | worker | **low** — additive, no caller | kind: listener binds only when flag set; `health` round-trips; unset ⇒ byte-identical `/metrics` and no port |
| 2 | Tier-service **client** + worker mirror can target it (`NOETL_EHDB_TIER_SERVICE_ADDR`), default unset ⇒ pod-local as today | worker | low | kind: shadow parity identical local vs remote; unset ⇒ unchanged |
| 3 | Read ops (`read`, `read_execution`, `tail`, `ack`) + wire the writer's durable store behind them | worker | medium | kind: read-back matches append; ack drives GC |
| 4 | **Server-side resolver** behind `NOETL_EHDB_TIER_SOURCE=service`, default `local` — `/api/ehdb/*` resolves via the service | server | medium | kind: `/api/ehdb/*` returns worker-written data; flag-off unchanged |
| 5 | `primary` **serve-and-verify** for one tier (KV), demote-on-divergence | worker+server | high | kind: primary serves, parity still emits, divergence demotes rather than fails |
| 6 | Ops: writer StatefulSet exposes `:9110`, Service + PodMonitoring, deployment-spec pages | ops+wikis | low | applied in kind; scrape selects it |
| 7 | Per-tier cutover runbooks + rollback drill | ai-meta | low | drill executed in kind |

**PR 1 is phase B of this effort** and is deliberately the most boring thing that
can be built: a listener that does not exist unless a flag is set.

---

## 6. Explicitly out of scope

- Multi-writer / cross-shard routing (`ShardOwnership` makes it a later
  extension).
- Replacing Postgres as the authoritative event log. Even fully built, this makes
  EHDB *serve* a tier; retiring the incumbent is a separate decision with its own
  evidence bar.
- Any prod flip. Prod serving stays gated on: full path proven in kind +
  accumulated prod shadow parity holding + **explicit per-tier go**.

---

## 7. Open questions for review

1. **Cutover order** — KV first is proposed as lowest-consequence. Object may be
   an equally good start; event-log is certainly last.
2. **Availability.** The writer is `replicas: 1`. Fronting tier reads there puts
   another dependency behind a single pod. Phase 1 is inert so this does not bite
   yet, but before PR 5 we should decide: accept it (as the buses already do), or
   pair it with the multi-writer work.
3. **Ephemeral vs durable for shadow.** Shadow needs no PVC and today writes
   pod-local under a **1Gi** limit with an **unbounded** JSONL log. Once PR 2
   lands, shadow can target the service instead and that caveat disappears — is
   that desirable sooner rather than later?
