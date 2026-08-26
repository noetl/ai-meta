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
