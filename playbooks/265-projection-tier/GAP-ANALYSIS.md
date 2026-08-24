# EHDB projection tier (tier 2) — serve-readiness gap analysis

**Date:** 2026-08-24 · **Tracks:** [ai-meta#265](https://github.com/noetl/ai-meta/issues/265)
**Verified against:** `noetl/worker` `origin/main` @ v5.120.0 + PR #277 rebased;
`noetl/server` `origin/main` @ v3.83.1 + PR #350 rebased. Prod not touched.

Everything below is read off the code or off a recorded gate run. Where a claim
rests on the 2026-08-14 gate rather than on a fresh run, it says so.

---

## 0. Headline

The projection tier is **write-proven and read-unbuilt**. Phase A gave it a
store, a serve *decision*, a server-authored mirror of the real incumbent rows,
and a comparator that discriminates — all kind-gated at 9 arms / 0 failures. But
**no reader anywhere resolves a projection from EHDB**: `orch_snapshot::load_latest`
answers from `noetl.projection_snapshot` unconditionally, and it is the only
read path. So `NOETL_EHDB_PROJECTION=primary` today means *"the write path claims
authority and says so"*, not *"the incumbent has been replaced"*.

That is the honest state, and it is deliberately stated rather than inferred
from `SERVE_WIRED_TIERS` membership — the #259 defect was exactly a description
that stopped tracking the code.

Two things also changed **under** the branch while it sat for ten days, and both
are now merged into it (§4).

---

## 1. What is built and wired

| piece | where | state |
| :-- | :-- | :-- |
| Per-tier store (own file, own lock) | `worker/src/ehdb/tier_store.rs` | built; `projection.jsonl` distinct from `eventlog.jsonl`, proven isolated by a 390-record cross-scan |
| Tier on the wire (absent ⇒ `eventlog`) | `worker/src/ehdb/tier_service.rs`, `tier_client.rs` | built; `kv`/`vector` refused 400, unknown tier answers `invalid` not `unsupported` |
| `POST /ehdb/tiers/{tier}` accepting `projection` | `worker/src/metrics_server.rs` | built |
| Serve decision on the **write** path | `worker/src/ehdb/projection.rs::serve_service_append` → `primary_serve::decide` | built; `SERVE_WIRED_TIERS = ["eventlog","projection"]` with the #259 guard re-deriving the list from the tier sources every `cargo test` |
| Server-authored mirror of the incumbent | `server/src/services/orch_snapshot.rs::save` → `handlers::ehdb_projection_mirror::mirror_snapshot` | built, default-off behind `NOETL_EHDB_PROJECTION_MIRROR_SOURCE=server`; inside the writer, guarded by an INSERT-site count |
| Cross-store comparator vs `noetl.projection_snapshot` | `server/src/handlers/ehdb_projection_parity.rs` | built; 8 divergence kinds, 9 outcomes, 9 self-controls pinned at 0 |
| Metric label sets pinned at 0 | `server/src/metrics.rs::init_ehdb_projection_series` | built, unconditional (not inside a config branch) |
| No pod-local projection write path | `worker/src/metrics_server.rs` | deliberate; `local` resolution refused **503** with a reason |

**Content parity here is stronger than the event log's.** `orch_snapshot::save`
already computes `sha256(snapshot)` and the mirror carries that value verbatim,
so the comparator compares two copies of **one** value rather than two
derivations. The event-log comparator cannot do this — the server rewrites
`context` → `result` and sanitises, so byte-identity is *defined* to fail there.

## 2. What is proven, and how far the proof reaches

From the 2026-08-14 gate (`playbooks/265-projection-tier/RESULTS.md`), 3 worker
replicas, locally built images, **9 arms / 0 failures**, controls
`expected=9 unexpected=0` before and after every arm:

- Tier addressing is real and closed, and **not satisfied by emptiness** — both
  stores were non-empty throughout.
- It is **one** store: all 3 replicas returned the same record for the same
  execution. The pod-local path this replaces does not have that property.
- `primary` reaches a serve decision, **two-sided**: the only variable that
  moved between the shadow and primary arms was `NOETL_EHDB_PROJECTION`, and
  `materialized=2` became `served_primary=1`, with the shadow arm pinned at
  **0 and present**.
- Demotion is loud: tier service pointed at a black hole ⇒ append answers 502,
  `outcome="unavailable"` ×5, `served_primary` stays 0.
- The comparator discriminates: a rewritten incumbent checksum reports
  `checksum`, **not** `stale_version` (a count-based check passes that);
  emptying the projection store reports `missing_execution` while the event log
  still held its 480 records.
- **Tier 1 never moved** — every arm ended with the event-log comparator at
  `match 13/13`.

**What the proof does NOT reach:** every one of those arms exercises the
**write** path. Nothing in the gate reads a projection out of EHDB and serves it
to a caller, because no code does that.

## 3. The genuine gaps, ranked

### G1 — There is no read-serve path at all (phase B1). *Blocking.*

`orch_snapshot::load_latest` (`server/src/services/orch_snapshot.rs:128`) is a
plain `SELECT … FROM noetl.projection_snapshot`, with exactly one caller:
`handlers::events::rebuild_state` (`events.rs:2071`). Until that resolves
through the tier service with a demote-to-incumbent fallback, `primary` on this
tier cannot change what any caller receives. This is the whole of the remaining
correctness work and everything else is downstream of it.

### G2 — Demote-on-divergence exists for the write, not for the read. *Blocking, part of G1.*

`primary_serve::decide` is consulted per append. A read-serve path needs its own
decision at the read: tier absent / behind the incumbent's version / checksum
mismatch must each fall back to Postgres and **say so**, rather than serve a
stale snapshot. Serving a stale read model is worse than serving none — the
caller folds events *after* `snap.version`, so an under-versioned snapshot
silently produces a state that never existed.

### G3 — The mirror is synchronous on the orchestrator's hot path. *High, latency.*

`mirror_snapshot` is an awaited HTTP POST (5s timeout) inside `orch_snapshot::save`,
and one of `save`'s two callers is the inline orchestrator self-write in
`trigger_orchestrator`. This is precisely the shape ai-meta#155 removed from the
event-log mirror, where it measured **78.6 ms → 0.1 ms per call** and moved the
median warm Muno turn 16.9 s → 13.0 s. The projection mirror has no async queue.

Note the coupling: making it async **requires** a lag-tolerance window on the
comparator, the way the event log has
`NOETL_EHDB_CROSSSTORE_PARITY_LAG_TOLERANCE_SECS`. Async-on with the window at 0
makes the comparator judge a healthy tier on its own liveness — **set both or
neither**.

### G4 — The incumbent writes sparsely, so "0 divergences" can be vacuous. *High, gates phase C.*

A 13-event execution completes and `noetl.projection_snapshot` gets **no row**:
the orchestrator's self-write needs `total == Some(cache.applied_count)` — a
throttled consistency COUNT — to coincide in the same pass, and on a short
execution it never does. The 3,344 kind rows came from the background reconcile
poller revisiting long-lived executions.

**The tier can only hold what the incumbent writes.** A shadow soak must
therefore publish a **coverage denominator** — what fraction of executions ever
get a snapshot — or a zero-divergence window means nothing. There is no such
denominator today: no metric answers "how many executions were eligible".

Related and pre-existing: `SNAPSHOT_INTERVAL_EVENTS >= 500` compares **snowflake
event ids**, not counts, so it is true on essentially every trigger.

### G5 — No ops manifests, no deployment-spec pages (phase B2). *Medium, blocks any prod shadow.*

Four new env vars (`NOETL_EHDB_PROJECTION`, `..._MIRROR_SOURCE`,
`..._PARITY_ENABLED`, plus the tier-service address the projection append needs)
appear in no `ops` manifest and on no deployment-spec wiki page. ai-meta#267
already found prod IaC omitting 84 live env vars; adding a fifth class of
undeclared variable is the same defect.

### G6 — The worker's own windowed fold is still labelled as projection evidence. *Low, documentation.*

`worker/src/ehdb/projection.rs` retains `shadow_project` / `fold_window_authoritative`,
which compares EHDB to a second copy of EHDB's own logic — the insufficiency
#258 ruled out for the event log. It is a useful engine conformance drive and
should stay, but nothing should read it as serve-readiness evidence.

### G7 — `noetl.projection` is still a live-looking dead table. *Low, disposition.*

0 rows, no Rust writer, only the retired Python `projection_store/postgres.py`.
Out of scope here; it needs a drop/annotate decision so the next reader does not
repeat the charter's mistake.

## 4. What changed under the branch while it sat (now merged in)

Both PRs were `CONFLICTING` on arrival — ten days of `main` moved beneath them.
Rebased 2026-08-24; the merges were not mechanical:

- **worker** — `main` landed #155's batched tier append (`append_batch`, one
  `fsync` per batch) and the `{path="batch"|"single"}` counters, on the same
  functions #265 made tier-generic. The batch path is now tier-addressed
  (`append_batch_tier`) and its serve decision dispatches per tier, so a
  projection batch cannot skip `decide` — that would have recreated #257's
  inert-serve-decision bug on a new path.
- **worker** — `main`'s append-path guard matched the literals
  `client.append_batch(&execution_id` / `client.append(&execution_id`. The
  rename to tier-addressed forms makes those count **zero on both sides**, i.e.
  the guard reports agreement by finding nothing. It now counts a whitespace-
  stripped, comment-stripped copy by prefix, and carries a positive control that
  the strippers did not eat the route literal. *A guard defeated by a rename is
  the same silent zero it exists to prevent.*
- **server** — `main` landed #155's async event-log mirror queue in the same
  region of `metrics.rs` and the same `init_*_series` block of `main.rs`. Both
  families are now registered; the projection tier still has no queue (G3).

Post-rebase: worker **690 lib tests pass**, server **797 lib tests pass**, no new
clippy warnings in either (the remaining warnings are pre-existing in
`event_write.rs`, `materializer.rs`, `control_plane.rs`).

## 5. What "serve-ready" would mean, concretely

1. **G1+G2** — `load_latest` resolves through the tier service, with a read-side
   `primary_serve::decide` that demotes to Postgres on absent / stale-version /
   checksum-mismatch and records which. Kind-gated with a *two-sided* arm: the
   only variable that moves is `NOETL_EHDB_PROJECTION`, and a mutated tier must
   produce a demote rather than a wrong answer.
2. **G4** — a coverage denominator published as a metric, so a soak's zero is
   readable.
3. **G3** — async mirror queue **plus** its lag-tolerance window, together.
4. **G5** — manifests + deployment-spec pages.
5. Then, and only then, prod shadow → soak → **explicit per-tier go**.

Steps 1–4 are code and are unblocked. Step 5 is the user's call and is not
scheduled.
