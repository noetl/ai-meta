# RFC — event-sourced control flow on EHDB: retiring the Postgres read model

**Status:** design / analysis. Nothing built, nothing rewired.
**Date:** 2026-08-26 · **Tracks:** [ai-meta#265](https://github.com/noetl/ai-meta/issues/265)
**Supersedes the framing of:** `ehdb-projection-tier-serve-path.md` (which
assumed the goal was *shadow the EHDB projection against the Postgres incumbent,
then cut reads over*).

> **The objective, restated.** The state the orchestrator reads to decide the
> next step of an execution should be derived from the **EHDB event log**,
> replacing the Postgres projections. Correctness is defined against the **event
> log**, not against a Postgres row.

Everything below §1 is measured against prod and `main` on 2026-08-26. Where a
claim is inferred rather than measured, it says so.

---

## 1. The finding that reframes the work

**Prod already builds orchestrator control-flow state from the EHDB event log.**
This is not a proposal — it is the running configuration:

```
noetl-worker-system-pool:
  NOETL_STATE_BUILDER=offserver
  NOETL_STATE_BUILDER_SOURCE=ehdb          ← the spine comes from EHDB
  NOETL_EVENT_BUS_WAL_ADDR=noetl-cmdbus-writer-0…:9108
  NOETL_STATE_SHARD_READ=true / WRITE=true ← object-store state shards
  NOETL_STATE_INDEX_REHYDRATE_ON_MISS=true
```

`worker/src/state_builder.rs::run_drain_loop_ehdb` subscribes to the EHDB events
feed, indexes each event with its `prev_event_id`, and `ExecutionChain::chain_walk`
walks head→root to produce the ordered spine that `WorkflowState::from_events`
folds. **Zero `noetl.event` scans, zero Postgres reads.**

So the question is not *"can control flow come from EHDB?"* — it does. The
question is **what is still Postgres-shaped, and what makes the EHDB-sourced
state verifiable.**

## 2. The control-flow read-dependency map

### 2.1 Decision points

`trigger_orchestrator_inner` (`server/src/handlers/events.rs:2799`) is the single
branch that decides how execution state is obtained. Both arms end in the same
`WorkflowOrchestrator`, so the *decision logic* is shared; only the **source of
state** differs.

```
trigger_orchestrator_inner
├── A. STATELESS OFF-SERVER DRIVE          ← the EHDB path
│     gate: orchestrate_plugin_drive
│         && state_builder == Offserver
│         && warm ExecDescriptor
│         && should_publish(catalog_id)     ← system execs are excluded
│     server reads: ZERO events, ZERO Postgres state
│       · catalog_id + routing ← in-memory ExecDescriptor
│       · expected_head        ← in-memory ChainHeads
│       · terminal             ← descriptor flag, stamped at the emit chokepoint
│     state built ON THE WORKER from the EHDB event spine
│
└── B. SERVER-BUILT FALLBACK               ← the Postgres path
      taken when: descriptor cold (server restart mid-execution)
                  OR the execution is a system/… execution
      server reads:
        · orch_snapshot::load_latest  → SELECT … FROM noetl.projection_snapshot
        · events-since                → SELECT … FROM noetl.event
```

Measured on prod after one real execution:

| `noetl_orchestrate_drive_total{stage}` | count |
| :-- | --: |
| `dispatched_offserver_stateless` / `applied_stateless` | 2 / 2 |
| `dispatched` / `applied` (server-built) | 10 / 3 |
| `cold_rebuild` | 1 |
| `offserver_retry` | 1 |
| `retrigger_recorded` / `skipped_in_flight` | 1642 / 1642 |

**Both arms run on prod today.** A is the steady state; B is recovery and the
system pool.

### 2.2 Where Postgres sits on the control-flow read path

| path | Postgres on the read path? |
| :-- | :-- |
| A — stateless off-server drive | **No.** |
| B — server-built fallback | **Yes**: `projection_snapshot` bounds the rebuild, `noetl.event` supplies events-since. |
| Worker-side spine (A) | No — EHDB feed, in-memory index, object-store shard on miss. |
| `noetl.catalog` (playbook YAML by `catalog_id`) | Yes, PK lookup. **Out of scope** — it is the program, not the state. |

### 2.3 The worker-side source of truth in A, in layers

1. **In-memory `WalEventIndex`**, fed by the EHDB feed drain. TTL 900 s, 256 MB cap.
2. **Object-store state shard** (`state_reader.rs`) on index miss — a Feather
   shard carrying the verbatim slim payloads, so the reconstructed chain is
   byte-identical to the WAL-replay chain *by construction*.
3. **EHDB replay-from-0** (`rehydrate_execution_from_ehdb`) when the shard is
   missing or stale, bounded by a deadline.

If none completes, the drive returns `__offserver_retry__` — a benign no-op the
reconcile poller re-drives. **Progress is deferred; state is never partially
built.** That fail-closed posture is the precedent this RFC extends.

### 2.4 On-server / kind topology

`state_builder=server` (the default, and what the kind cluster runs): arm A never
fires, and every trigger takes arm B. So **kind exercises the Postgres path and
prod mostly does not** — which is why the #265 kind gates could prove the
projection tier's mechanics while telling us nothing about prod's control flow.

## 3. Is the Postgres projection deliberately retired? — a qualified **no**

**Measured:** on prod, `noetl.projection_snapshot` receives **no writes at all**.
Both of `orch_snapshot::save`'s call sites are idle:
`noetl_ehdb_projection_snapshot_gate_total` reads 0 on **every** label including
the `skipped_*` ones (so `trigger_orchestrator_inner`'s snapshot gate is not
*reached*, not reached-and-skipped), and `noetl_projection_advanced_total` is 0
(the projector's `/api/internal/projection/advance` does not run). The comparator
answers `no_authoritative` for a freshly driven execution.

**The honest reading is not "it was retired".** It is:

> The snapshot is written **only on path B**, and path B is the path prod
> mostly does not take. It was never switched off; it fell out of use as a
> side effect of `state_builder=offserver`.

That distinction matters because of what the snapshot is *for*: it **bounds** path
B's rebuild. Unbounded replay is what OOM'd the server at ~19k events and is the
reason `orch_snapshot` exists at all.

### ⚠ 3.1 A latent risk this analysis surfaces, independent of the EHDB work

Path B is the **recovery** path — a server restart mid-execution takes it. On
prod today it would find **no snapshot**, and therefore replay from the
beginning of the execution. The mechanism built to prevent an OOM is present,
armed, and empty exactly when it would be needed.

Nothing has hit this because prod has no user traffic and executions are short.
It is not caused by #265 and it is not fixed by it. **Recommend tracking
separately.**

### ⚠ 3.2 A second one: the byte-equivalence guard is off on prod

`NOETL_STATE_SHARD_READ_VERIFY=false`. `state_reader.rs` says *"Never serves
divergent state"* — true **only when that flag is on**, because it is the flag
that runs the dual build and byte-compares shard-loaded state against the WAL
replay. Off, the object-store shard path feeds control-flow decisions with no
verification that it reconstructed the same spine.

This is the closest existing analogue to what §4 proposes, it is already built,
and it is currently not verifying. **Turning it on is the cheapest possible
first step toward the goal**, and it is independent of everything else here.

## 4. Design — the projection tier as the verifiable EHDB read model

### 4.1 What changes conceptually

Today the EHDB-sourced control-flow state is **ephemeral**: an in-memory index
per pod, rebuilt from the feed, with object-store shards as a cache. There is no
durable, addressable, *verifiable* execution-state read model.

The projection tier becomes exactly that:

> **`projection[execution_id] = fold(events(execution_id))`**, materialised from
> the event log, durable in the tier, addressable by execution, and carrying the
> digest of the state it represents.

The Postgres `projection_snapshot` stops being the thing to agree with and
becomes, at most, a migration artifact.

### 4.2 Correctness defined against the event log

The #265 comparator compares the tier against a Postgres row. **That definition
is retired by this RFC.** The replacement:

> A projection record at `version = V` is **correct** iff
> `sha256(fold(events(execution) where event_id ≤ V))` equals the digest the
> record carries, where `fold` is the *same* `WorkflowState::from_events` the
> orchestrator uses.

Three properties follow, and each is testable without Postgres:

| property | check |
| :-- | :-- |
| **Determinism** | fold the same event set twice, in two processes → identical digest. Already relied on: `state_reader`'s dual build asserts byte-equivalence today. |
| **Completeness** | the record's `version` equals the execution's chain head at fold time, and every event from genesis to `version` was present. A gap is a **refusal**, not a fold. |
| **Freshness** | `chain_head(execution) − version` bounded by the lag window. Beyond the window the projection may not drive a decision. |

⚠ Digest determinism is **assumed** and must be proven first, not assumed into
the design: `WorkflowState` serialisation must be canonical (stable map
ordering). I measured a *stable* checksum across four prod-shaped rebuilds of one
execution in kind, which is evidence and not proof. **Phase 0 below is exactly
this proof.**

### 4.3 Fail-closed behaviour — the part that matters most

Control flow must **never advance an execution on unverified state.** The rule,
in precedence order, and every outcome is *defer*, never *guess*:

| condition | control-flow action | why not otherwise |
| :-- | :-- | :-- |
| projection absent for the execution | **defer** — no-op, reconciler re-drives | absence is not "empty state"; folding from nothing invents an execution at step 0 |
| `version` < chain head, inside window | **defer** | the fold has not caught up; advancing would re-issue a completed step |
| `version` < chain head, beyond window | **defer + alert** | this is a stalled materialiser, not a slow one |
| `version` > chain head | **defer + alert (loudest)** | claims an event that does not exist; the #265 `version_ahead` case, and the only one that can produce a state that never existed |
| digest mismatch | **defer + alert** | the record does not describe its own content |
| chain gap detected during fold | **defer** | a fold over a gapped spine is a different execution's history |
| tier unavailable | **defer** | |

**`defer` is not a fallback to Postgres.** It is the existing
`__offserver_retry__` shape: return a benign no-op, let the reconcile poller
re-drive. That is the single most important design decision here — a fallback
that silently reads a *different* store on error is how two sources of truth get
established, and this whole effort is about having one.

Two consequences to accept deliberately:

- **A permanently-unavailable tier stalls executions.** That is correct
  fail-closed behaviour and it must be alerted on, not softened.
- **The reconciler becomes load-bearing**, not just a straggler backstop. Its
  interval (8 s) becomes a control-flow latency floor under degradation.

### 4.4 Where the fold runs

The event-sourced fold belongs **beside the event log, on the writer** — the
process that already holds every event and can detect a gap without a network
hop — not on N worker pods each folding independently.

*Recorded as the open design question rather than settled*, because it is the
one place this RFC would change platform shape rather than extend it. Options:

1. **Writer-side materialiser** — folds on append, writes the projection record
   into the tier. One folder, no coordination, gap detection is local. Cost: the
   writer gains domain knowledge of `WorkflowState`, which it currently does not
   have.
2. **System-pool materialiser** — the existing pool folds from the feed and
   appends to the tier via the server API (`data-access-boundary.md` compliant).
   Cost: N folders need dedup/ordering discipline; the projection tier's
   single-writer property has to be enforced rather than structural.
3. **Server-side on the emit chokepoint** — the shape #265 A3 built for the
   Postgres mirror, retargeted to fold rather than copy. Cost: puts folding back
   on the server the off-server work removed it from.

**Recommendation: (2)**, because it preserves the data-access boundary and reuses
the pool that already drains the feed — but it must ship with the single-writer
property *tested*, not assumed. Deciding this is Phase 1's output, not this
document's.

## 5. Staged proof path

Nothing moves to the next phase without the previous one's evidence.

### Phase 0 — prove the fold is deterministic *(no new code paths)*

The premise everything rests on. Fold the same event set in two processes and on
two machines; assert identical digests. Include a **negative control**: perturb
one event's payload by one byte and assert the digest changes.

Cheap adjacent win: turn **`NOETL_STATE_SHARD_READ_VERIFY=true`** on in kind,
then propose it for prod. It is the same property, already implemented, currently
off (§3.2).

**Exit:** determinism proven, or `WorkflowState` serialisation made canonical
until it is.

### Phase 1 — the materialiser, shadow only

Fold from the event log into the projection tier. Writes the tier; **nothing
reads it.** Decide §4.4 here, with the single-writer property tested.

**Exit:** for a population of kind executions, every projection record's digest
equals an independent re-fold, and coverage — records written / executions
driven — is **published as a metric**, not inferred. #265's G4 lesson: a
denominator that only exists in prose is a denominator nobody reads.

### Phase 2 — the comparator, against the event log

Not against Postgres. Re-fold from the log and compare to the stored record.
Fail-closed vocabulary from §4.3, each reason its own label, each with a control
that proves it can fire.

**Exit:** every §4.3 condition demonstrated firing in kind, two-sided (the
healthy case must also be shown, or a comparator that always defers passes).

### Phase 3 — control flow reads it, in kind, behind a flag

> **Re-scoped 2026-08-26.** The flag-OFF/flag-ON command-stream gate below does
> not fit the topology this actually runs on, and §9 replaces it. The short
> version: on the off-server topology the drive is *already* WAL-sourced and
> never calls `load_latest`, so turning the flag on changes nothing to compare.
> The read that was still on Postgres is **recovery**. Read §9 instead of this
> section; it is kept for the record of what was originally planned.

`NOETL_STATE_SOURCE=projection`, default off. The drive obtains state from the
tier; on any §4.3 condition it **defers**.

**Exit gate — the strongest one, and the reason this is staged at all:** run the
same executions with the flag off and on and assert the **commands issued are
identical**. Control flow is a function of state; two states that produce the
same command stream are equivalent for our purposes, and that is a stronger and
more honest check than comparing state blobs.

Plus: a fault arm per §4.3 row, proving each **defers rather than advances**.

### Phase 4 — prod shadow

Materialiser + comparator on prod; control flow still on the existing path.
Gather what kind cannot: real chain depth, real feed lag, real restart/rehydrate
behaviour, real concurrency across replicas.

**Exit:** a real window with zero unexplained defers **and** a coverage
denominator showing the sample was real.

### Phase 5 — control-flow cutover. **Explicit owner go, per step.**

Not scheduled, not designed in detail here, and deliberately so.

## 6. Boundaries this RFC does not cross

- Prod control flow is **not** rewired. `NOETL_STATE_BUILDER` and every
  `NOETL_EHDB_*` serve flag stay as they are.
- The event-log tier stays `primary`.
- No writes are driven into Postgres snapshot tables on prod.
- `noetl.projection` (the dead table, 0 rows, no Rust writer) stays out of scope;
  its disposition is #265 G7.

## 7. What #265's work is worth under this reframing

| built | still worth it? |
| :-- | :-- |
| tier-generic store, wire protocol, per-tier locks (A1) | **Yes** — the substrate the projection read model needs. |
| serve decision + `SERVE_WIRED_TIERS` (A2) | **Yes** — the demote vocabulary maps onto §4.3. |
| server-authored mirror of `projection_snapshot` (A3) | **Superseded.** It copies a Postgres row; §4.2 folds from the log. Keep as the migration path if one is wanted; do not build on it. |
| comparator vs `projection_snapshot` (A4) | **Retarget** — same machinery, ground truth becomes the re-fold. The 9 controls carry over intact. |
| read-serve + fail-closed demote (B1/G1/G2) | **Yes, directly** — §4.3 is its generalisation. |
| async queue + lag window (G3) | **Yes** — a materialiser needs both, and the pairing rule is unchanged. |
| coverage denominator (G4) | **Yes, and it becomes central** — §5 Phase 1's exit criterion. |
| ops manifests, drift check, deployment specs (G5) | **Yes** — unaffected by the reframing. |

The honest summary: **A3 is the piece the reframing supersedes.** Everything else
either carries over or becomes more important.

---

## 8. What the kind build actually established (2026-08-26)

Everything in this section is measured. Where something was **not** established,
it says so.

### 8.1 Three findings that changed the design

**A. The fold was not deterministic — and the cause was a loader bug, not the fold.**
`noetl.event.created_at` is a Postgres `timestamp` (tz-less); the loader read it
as `timestamptz`, failed on **every row**, and substituted `Utc::now()`. Since
`apply_event` propagates `event.timestamp` into `started_at` / `completed_at` /
`entered_at`, every rebuild embedded *the moment of the rebuild*. Folding the
same in-memory events twice was byte-identical; folding two reads of the same
rows was not. Fixed in server#357; two replicas diverging on those timestamps is
tracked independently as [#296](https://github.com/noetl/ai-meta/issues/296).

**B. The WAL spine is a LIVE-execution structure.** The index evicts a chain on a
terminal event, by design — a completed execution never needs driving again. So
a completed execution has **no spine** and correctly reads `incomplete`.
Anything folded from the spine must be folded **while the execution is in
flight**, which is the right shape for control flow: it reads state to decide
the *next* step, and a completed execution has none.

**C. The spine relay must target the pool that runs the drain.**
`NOETL_EHDB_WORKER_QUERY_URL` feeds both tier reads and the spine read, but only
the system pool runs the state-builder. Pointed at the user pool every spine read
returns `incomplete` — silently, because an empty index answers `incomplete`, not
`unavailable`. Measured two-sided on one live execution: system `[ok n=6]`, user
`[incomplete n=0]`.

### 8.2 §4.2's correctness definition survives — after one correction

The equivalence arm (WAL-spine fold vs incumbent fold, same execution, same
version, same event count) **failed** on exactly one field:

```
/started_at: "2026-08-26T05:01:33.645451Z" != "2026-08-26T05:01:33.645451448Z"
                          └ µs (Postgres)              └ ns (WAL envelope)
```

Postgres `timestamp` stores microseconds; the event-bus envelope carries
nanoseconds. Normalised on the fold's **input** — not inside the digest, because
that would leave the states genuinely different while agreeing on a hash, and
the drive reads those fields directly.

⚠ The first attempt **truncated** and got 1 of 4. Postgres **rounds half-up**;
the residual was exactly one microsecond. With rounding: **8 / 8 MATCH,
diffs=0**, controls green before and after.

### 8.3 Option 3 stands — the WAL spine IS a sufficient source

The check that mattered, since the event-log tier failed exactly here. Input
field presence, both sides, same execution:

| | Postgres | WAL spine |
| :-- | --: | --: |
| events | 4 | 4 |
| **with_context** | **2** | **2** |
| with_result | 2 | 2 |
| with_meta | 4 | 4 |
| with_attempt | 1 | 1 |
| distinct_created_at | 4 | 4 |

Identical on every field the fold reads, **including `context`** — the field the
event-log tier lacks and which `apply_event` reads in six places (that tier
diverged 12/12). **§4.4's source question is settled: the WAL spine.**

And the worker does **not** fold. `WorkflowState` lives in the server's
`orchestrate-core`; the worker serves the ordered spine and the server folds it.
A second fold implementation is the one thing an event-sourced read model must
not have.

### 8.4 Fail-closed vocabulary — every verdict fired for real

One fresh **live** execution per arm (a crafted record shadows the next arm
otherwise — newest-by-version wins):

| arm | verdict | fault? |
| :-- | :-- | :-- |
| agreement | `match` | no |
| same version, different content | `digest_mismatch` | **yes** |
| claims an event the log lacks | `stored_ahead_of_spine` | **yes** |
| materialiser lagging | `stored_behind_spine` | no |
| nothing materialised | `no_stored_record` | no |
| terminal execution, no spine | `spine_refused` | no |

**6 / 6 pinned labels reachable** — confirmed on `/metrics`, not inferred. A
verdict that has never fired is indistinguishable from one that cannot.

### 8.5 NOT established

- **Identical command streams, flag OFF vs ON.** Control flow is not yet wired
  to read the WAL-sourced projection — the materialiser that writes folded
  records into the tier is not built — so there is no "ON" to compare. The
  equivalence result (§8.2) is the input to that claim, not the claim.
  *(Superseded 2026-08-26: the materialiser now exists, and §9.1 explains why
  this comparison cannot be constructed on the off-server topology at all —
  arm A never calls `load_latest`, so both sides of an OFF/ON gate would miss
  the code under test. §9.3 is the gate that replaces it.)*
- **The credential limit is not closed.** Redone on the rebuilt kind population:
  374 events, 89 with context, **0** credential-shaped, 0 bearer-shaped, 0
  PEM-shaped. That zero is **vacuous** — the rebuilt population contains no
  credential-using executions, so the check had nothing to find and no positive
  control. The substantive measurement remains the pre-truncation one: 25,653
  events, 8 credential-shaped rows, **every one a bare 26-character alias**, not
  resolved material. Closing this properly needs a population that exercises
  credentials.
- **The `unavailable` branch is unreachable** in the normal worker shape
  (`worker.rs` always passes `Some(index)`), so an empty index answers
  `incomplete`. Measured, not assumed.

---

## 9. Phase 3, re-anchored — recovery is the read that was left (2026-08-26)

Owner decision, and the reason the section above is superseded:

> Go with Option 3 — re-scope Phase 3. Since control flow is already
> WAL-sourced on the off-server topology, the remaining work is to make the
> durable EHDB read model also the source for the **recovery** path
> (`load_latest`), retiring the Postgres projection from the control-flow read
> path entirely, including recovery.

### 9.1 Why the original gate could not be run

Phase 3 as written asks for the same executions under flag OFF and flag ON, with
identical command streams. Building it revealed that on the topology in question
there is no OFF/ON distinction to make.

`trigger_orchestrator_inner` has two arms. Arm A — the stateless off-server drive
— walks the spine and **never calls `load_latest`**. Arm B is the server-built
fallback, and `load_latest` is *its* read. With
`NOETL_STATE_BUILDER=offserver` + `SOURCE=ehdb`, kind takes arm A on every
execution:

```
orchestrate_drive_total{stage="applied"} 1
orchestrate_drive_total{stage="applied_stateless"}   ← absent
```

Flipping `READ_SOURCE` therefore moved nothing, and a gate showing "identical
command streams" would have passed because **neither** side exercised the code
under test. That is the shape this repo has been bitten by repeatedly: a check
that cannot fire is indistinguishable from a check that passes.

### 9.2 What was actually left on Postgres

Recovery. When the stateless drive is unavailable — replica restart, spine
eviction, arm-B fallback — control flow reloads state via `load_latest`, and that
read went to `noetl.projection_snapshot`. Retiring the Postgres projection from
the control-flow read path *entirely* means retiring it there too.

`ReadSource::Wal` is the fourth mode. The Wal branch of `load_latest`:

1. `materialize_from_wal` folds the spine into a projection record;
2. `wal_projection_state` verifies the stored record against the spine;
3. on **any** non-`Match` verdict it returns `Ok(None)` — and **never** reads
   Postgres as a fallback.

So recovery either returns state just verified against the event log, or returns
nothing and the execution does not advance. There is no path from a doubtful
record to a drive decision. Guarded by
`the_wal_mode_never_reaches_for_the_incumbent`.

### 9.3 The gate that fits — recovery equivalence, 6/6

Same execution, same version, both sources, digest-compared, on live in-flight
executions. `recovery_read_comparison` runs `load_incumbent` (the pre-#265
Postgres read) and `wal_projection_state` side by side and reports `agree` only
when both are present and equal.

```
run1: AGREE pg=91714aea046d wal=91714aea046d verdict=match
run2: AGREE pg=7cba69b4050a wal=7cba69b4050a verdict=match
run3: AGREE pg=25f5903f6dde wal=25f5903f6dde verdict=match
run4: AGREE pg=34cca1d3dc08 wal=34cca1d3dc08 verdict=match
run5: AGREE pg=27b97f6a37f1 wal=27b97f6a37f1 verdict=match
run6: AGREE pg=be85a4c8baa6 wal=be85a4c8baa6 verdict=match
============ RECOVERY EQUIVALENCE: 6 / 6 comparable ============
```

Controls green before (`controls_ok=true expected=9 unexpected=0`) and after.
Together with the 8/8 fold equivalence (§8.2) and fold determinism (§8.1), this
is the equivalence evidence the owner asked to lean on.

### 9.4 The fault arms — and the one that inverted

Three of four behaved as designed; two "failures" turned out to be a **design
property that had not been stated**, and finding out which required a positive
control rather than a re-run.

Because `wal_projection_state` **materialises before it verifies**, an injected
stale or divergent record is overwritten by a fresh correct fold *before* the
read happens. Newest-by-version wins, so the bad record is simply gone. Recovery
reports `match` — which is exactly what a test that failed to inject anything
would also report.

The control that separates those two explanations: one injected-bad execution,
two endpoints, one of which does not materialise.

| endpoint | materialises? | verdict |
| :-- | :-- | :-- |
| `/api/ehdb/projection-refold/executions/{id}` | no | `digest_mismatch` |
| `/api/ehdb/projection-recovery/{id}` | **yes** | `match` |

The fault was present and was detected. It was **corrected, not missed**.

That makes the honest statement about this path: it **repairs** on stale and
divergent, and **refuses** on what a re-fold cannot fix. Both refusals were
exercised:

```
PASS ahead of the log   verdict=stored_ahead_of_spine  REFUSED (wal_present=false)
PASS spine_refused                                     REFUSED (wal_present=false)
```

`stored_ahead_of_spine` survives repair precisely because it claims a higher
version than the log can justify — the one case where the stored record is not
merely behind the truth but asserts something the event log does not contain.
Refusing there is the correct and non-negotiable behaviour.

Repair is a **stronger** property than refusal — control flow gets correct state
instead of stalling — but it changes which verdicts are reachable on this path,
and that had to be recorded rather than left as two red lines in a gate log.

### 9.5 The finding that matters most

The Postgres recovery source is **empty by construction** on this topology:

```
noetl_ehdb_projection_snapshot_gate_total{outcome="written"} 0
noetl_projection_advanced_total                             0
```

Nothing on the off-server path writes `noetl.projection_snapshot`. The rows that
existed came from manual `POST /api/internal/projection/advance` calls made to
populate the comparison side of the gate. Without them, the gate's first run was
`0/6` with `pg=-` on every execution.

So the durable EHDB read model is not merely *equivalent* for recovery — it is
the **only source with data in it**. A recovery on the current prod topology
would find nothing in Postgres. This is the same hazard §3.1 flagged from the
other direction, now measured: the Postgres projection is not a working fallback
being kept warm, it is an empty table being kept.

### 9.6 Option 3 still stands

Nothing in this phase argued for widening the tier's `mirror_payload` to carry
`context`. The recovery fold reads the same `SLIM_EVENT_KEYS` spine the drive
does, and produced digest-identical state to the Postgres read on 6/6. The
credential constraint is honoured by construction: no credential-bearing
`context` is persisted into any tier store.

### 9.7 Status — Phase 3 re-scoped and **complete**

| | |
| :-- | :-- |
| Recovery equivalence | **6/6**, digest-identical, live in-flight executions |
| Fold equivalence (§8.2) | 8/8 |
| Fold determinism (§8.1) | established |
| Repair property (§9.4) | characterised, positive-control-proven |
| Refusal arms | `stored_ahead_of_spine`, `spine_refused` — both exercised |
| Postgres on the control-flow read path | **retired, including recovery** |
| Landed | noetl/server#358 → **v3.88.0**, ai-meta@`0b6fba5a` |
| Activation on prod | none — `NOETL_EHDB_PROJECTION_READ_SOURCE` undeclared |

### 9.8 Three decisions held for the owner

Recorded here so they do not evaporate between sessions. **None of these has
been acted on.**

1. **#297 fix location — (a) / (b) / (c).** The mechanism is named and corrected
   (`ClaimClient::claim_next` → `read_frame` with no timeout, parking forever
   while the worker holds the source mutex across the await). The fix is built
   but not merged, pending the choice between (a) the ehdb-feed dependency fix
   plus re-pin, (b) a worker-side timeout wrapper, (c) both.
2. **Disposition of `noetl.projection_snapshot`.** §9.5 measured it empty by
   construction on the off-server topology — a Postgres recovery on current prod
   would find nothing. Whether to drop the table, restore a writer, or leave it
   and treat §3.1's hazard as accepted is an owner call.
3. **Whether any merged fix reaches prod.** Everything on this track is merged
   inert and released but **not deployed**. A prod roll needs its own explicit
   go, separately from the merges.

### 9.9 Still open after this phase

- **The credential limit.** No credential-exercising execution was run in kind,
  so whether the spine carries unmasked resolved `context` under a real provider
  call is **unestablished**. The standing evidence remains the pre-truncation
  scan: 25,653 events, 8 credential-shaped rows, every one a bare 26-character
  alias rather than resolved material. Closing it needs a population that
  exercises credentials — deliberately not driven here, since that means a real
  provider call.
- **Disposition of `noetl.projection_snapshot`.** §9.5 makes it an empty table on
  the live topology. Dropping it, or restoring a writer, is an owner call and is
  not made here.
- **Phase 4 (prod shadow) and Phase 5 (cutover)** are unchanged and untouched.
  `NOETL_EHDB_PROJECTION_READ_SOURCE` is undeclared on prod; server#358 is inert
  on merge.
