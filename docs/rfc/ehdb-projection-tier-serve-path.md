# RFC — EHDB projection tier (tier 2): what it must mirror, and what "serve" means

**Status:** draft, built against
**Date:** 2026-08-13
**Tracks:** [noetl/ai-meta#257](https://github.com/noetl/ai-meta/issues/257) (parent),
[#258](https://github.com/noetl/ai-meta/issues/258) (the comparator pattern this reuses)
**Author:** Claude (session 2026-08-13)

Companion to [`ehdb-primary-serve-path.md`](ehdb-primary-serve-path.md), which
took the **event-log** tier (tier 1) to serving primary in prod on 2026-08-13.
This note does the same survey for the **projection** tier (tier 2) and records
what the survey found — which is not what the charter assumed.

---

## 1. Four findings that change the design

Every row below was measured this session against the kind cluster's Postgres
and the current `main` of `noetl/server` + `noetl/worker`. None is inferred.

### 1.1 `noetl.projection` is a dead table. It is not the target.

The charter names "the `projection` + `projection_snapshot` tables" as what the
projection tier replaces. Half of that is wrong:

| evidence | result |
| :-- | :-- |
| rows in `noetl.projection` (kind) | **0** |
| `INSERT INTO noetl.projection` in `noetl/server` | **none** |
| `INSERT INTO noetl.projection` in `noetl/worker` | **none** |
| the only writer that exists | `repos/noetl/noetl/core/projection_store/postgres.py:69` — the **retired Python** path |

`noetl.projection` is a Python-era reference table that the Rust control plane
has never written. It is the same shape of thing as
`noetl.execution.status` ([#235](https://github.com/noetl/ai-meta/issues/235)):
a column/table that reads like live data and is frozen.

**Consequence for the build.** A comparator pointed at `noetl.projection` would
read a 0-row table on both sides and report perfect parity, forever, on a tier
that mirrors nothing. That is a vacuous pass of exactly the kind
[`representation-drift.md`](../../agents/rules/representation-drift.md) exists
to catch, and it is the first thing this design would have got wrong.

`noetl.projection` is **out of scope**. Retiring it is a disposition decision
(drop / annotate), tracked separately.

### 1.2 The authoritative projection is `noetl.projection_snapshot`, and it has exactly one writer

| | |
| :-- | :-- |
| rows (kind) | **3,344** |
| distinct `aggregate_type` | **1** — `orchestrator_workflow_state` |
| `INSERT INTO noetl.projection_snapshot` sites in `noetl/server` | **exactly 1** — `src/services/orch_snapshot.rs:71` |
| read path | `orch_snapshot::load_latest` → `handlers::events::rebuild_state` |

The row is a per-execution CQRS read model: `aggregate_id` = `execution_id`,
`version` = highest `event_id` folded, `snapshot` = the serialised
`WorkflowState`, `checksum` = SHA-256 of that snapshot, `meta.applied_count` =
events folded in.

**This is a better chokepoint than the event log ever had.** The event-log
mirror needed three call sites and still shipped a bypass on the system pool
([#263](https://github.com/noetl/ai-meta/issues/263)) because `emit_events` was
"almost" the one place every event passes through. `orch_snapshot::save` is
*actually* the one place, and the mirror therefore goes **inside `save`**
rather than beside its callers — a bypass would have to be a second `INSERT`,
which a guard test can count.

### 1.3 The existing EHDB projection tier mirrors a **different read model** than the incumbent

`worker/src/ehdb/projection.rs` is substantial (65 KB, `PRIMARY_SERVE_ACTIVATED
= true`, a full `serve_primary_cycle`). It is also not a mirror of
`projection_snapshot`. It folds events into its own per-execution state rows
(`list_executions` / `read_execution_state` / `read_event`) and parity-checks
them against an independent worker-side fold of the same window
(`fold_window_authoritative`).

That is a genuine self-consistency drive, and it is exactly the class of signal
[#258](https://github.com/noetl/ai-meta/issues/258) ruled insufficient for the
event log: **it compares EHDB to a second copy of EHDB's own logic, not to the
incumbent's stored rows.** `shadow_project`'s `authoritative` argument is a fold
the worker computed, not anything read from `noetl.projection_snapshot` — and
per [`data-access-boundary.md`](../../agents/rules/data-access-boundary.md) the
worker cannot read it.

So the projection tier today holds a read model the incumbent does not have,
verified against a fold the incumbent did not produce. Promoting *that* to
primary would replace `projection_snapshot` with something that was never
compared to it.

**Consequence for the build.** The projection tier needs the same closure the
event log got: a **server-authored mirror of the incumbent's actual rows**, and
a **cross-store comparator that reads both stores**. The existing windowed fold
stays — it is a useful engine conformance drive — but it is not the serve-
readiness evidence and this note stops treating it as such.

### 1.4 Snapshots outlive their events, by 138×

| | |
| :-- | :-- |
| snapshot rows | 3,344 |
| snapshot rows whose execution has **no surviving events** | **3,320** |
| executions with both events and a snapshot | **24** |

Event retention trims `noetl.event`; `projection_snapshot` is an upsert with no
matching GC, so it accumulates. This is not a defect to fix here, but it is a
**hard constraint on the comparator**: a presence check over the whole table
would report 3,320 missing rows on the day the mirror arms, drowning any real
divergence in a backlog the mirror was never going to hold.

The comparator is therefore scoped **per execution**, over executions whose
snapshot was written after the mirror armed — the projection-tier analogue of
`mirror_expected` in the event-log comparator. An execution the mirror could
not have seen is reported as itself (`unmirrored_by_design`), never as
divergence.

### 1.5 (minor, pre-existing) `SNAPSHOT_INTERVAL_EVENTS` does not mean 500 events

`handlers/events.rs` gates the orchestrator's self-write on
`cache.last_event_id - cache.snapshot_version >= 500`. Both operands are
**snowflake event ids**, not counts — consecutive events differ by far more than
500 — so the condition is true on essentially every trigger. Measured: 3,344
snapshot rows carrying `applied_count = 12`, i.e. one upsert per trigger on
~13-event executions.

Not this RFC's to fix, and it is benign (the upsert is idempotent and monotonic).
It is recorded because it sets the **mirror's write volume**: roughly one
projection append per orchestrator trigger per execution, not one per 500 events.
A capacity estimate taken from the constant's name would be off by two orders of
magnitude.

---

## 2. What "mirror" and "serve" mean for tier 2

Reusing the event-log vocabulary exactly, so the two tiers stay legible together.

| | event-log tier (tier 1, shipped) | projection tier (tier 2, this RFC) |
| :-- | :-- | :-- |
| authoritative store | `noetl.event` | `noetl.projection_snapshot` (`aggregate_type = orchestrator_workflow_state`) |
| write chokepoint | `handlers::event_write::emit_events` **+ 2 in-tx sites** (#263) | `services::orch_snapshot::save` — **one site**, mirror goes inside it |
| mirror record | the authoritative row's identifying projection + full row | `execution_id`, `version`, `checksum`, `applied_count`, `snapshot` |
| mirror flag | `NOETL_EHDB_EVENTLOG_MIRROR_SOURCE=server` | `NOETL_EHDB_PROJECTION_MIRROR_SOURCE=server` |
| comparator | `handlers::ehdb_parity` vs `noetl.event` | `handlers::ehdb_projection_parity` vs `noetl.projection_snapshot` |
| identity axis | `event_id` | `version` (highest folded `event_id`) — monotonic per execution |
| content axis | `event_type` / `node_name` / `status` | `checksum` (SHA-256 the server already computes) + `applied_count` |
| serve signal | `served_primary` at the service-resolved append | same, on the projection tier's append |
| eventual read-serve | server resolves `noetl.event` reads through the tier | server resolves `load_latest` through the tier |

**Content parity is cheaper and stronger here than for the event log.** The
event-log comparator explicitly cannot compare bodies — the server rewrites
`context` into a `result` envelope and sanitises it, so byte-identity is defined
to fail. The projection snapshot has no such rewrite, and the server *already
computes a SHA-256 of exactly the bytes it stores* (`orch_snapshot::save`). The
mirror carries that checksum, so content parity is a string comparison against a
digest the incumbent authored. Nothing is re-derived, so nothing can disagree by
being derived differently.

---

## 3. Phases

Phase A is what this session builds. B and C are the handoff.

| phase | what | repo | state |
| :-- | :-- | :-- | :-- |
| **A1** | Tier substrate becomes **tier-generic**: per-tier stores in `tier_store`, `tier` on the wire protocol (absent ⇒ `eventlog`, so a PR-3 client keeps working), `/ehdb/tiers/{tier}` accepts `projection` for GET and POST | worker | **this session** |
| **A2** | Projection **serve decision** through `primary_serve::decide` at the service-resolved append; `SERVE_WIRED_TIERS += "projection"`; the #259 guard test re-derives it from source | worker | **this session** |
| **A3** | Server-authored **projection mirror** inside `orch_snapshot::save`, default-off | server | **this session** |
| **A4** | **Cross-store comparator** vs `noetl.projection_snapshot`, with in-binary controls | server | **this session** |
| **B1** | **Read-serve**: `orch_snapshot::load_latest` resolves through the tier service when the tier is primary, demoting to the Postgres row | server | handoff |
| **B2** | Ops: writer StatefulSet, PodMonitoring selector, deployment-spec pages for the new env vars | ops + wikis | handoff |
| **C** | Prod shadow soak → zero-divergence window → **explicit per-tier go** → flip | — | gated on the user |

**A is the honest boundary of "flip-ready".** After A the tier holds the
incumbent's rows, a comparator proves it holds them correctly, and the write
path can claim authority with the same three-condition policy the event log
uses. What A does **not** do is make any reader read from it — that is B1, and
until B1 lands a `primary` projection tier changes what is *measured*, not what
is *served to a caller*. Saying otherwise would repeat
[#259](https://github.com/noetl/ai-meta/issues/259), where a doc comment claimed
a serve path that did not exist.

---

## 4. Acceptance gates

Unchanged from [`ehdb-primary-serve-path.md`](ehdb-primary-serve-path.md) §4 —
behaviour-level on built images in kind, two-sided, positive control,
mutation-checked with a mutation that compiles, fail loud, parse with a parser,
flag-gated and default-off.

Two additions specific to this tier, each from a finding above:

8. **The comparator must be shown to discriminate against `projection_snapshot`
   specifically.** A control that passes against an empty table is the §1.1
   trap. The gate asserts a non-zero authoritative row count before scoring any
   parity verdict.
9. **The backlog must be visibly excluded, not silently.** The 3,320
   pre-mirror snapshots are reported under their own outcome label. A comparator
   that scoped them away without saying so would make its own coverage
   unmeasurable.

---

## 5. Rollback

Same shape as tier 1, and safe for the same reason: **the mirror only appends
to EHDB and never touches `noetl.projection_snapshot`.** The incumbent upsert
runs unchanged in every mode, so:

- `NOETL_EHDB_PROJECTION_MIRROR_SOURCE` unset ⇒ no append, byte-identical.
- `NOETL_EHDB_PROJECTION=shadow` ⇒ mirror + compare, incumbent authoritative.
- `NOETL_EHDB_PROJECTION=primary` ⇒ additionally claims serve authority on the
  write path; demotes to the incumbent on divergence or an unreachable service.

Rollback is the flag back. Nothing to un-write.
