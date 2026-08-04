# #227 part B — the non-convergence sweep, and what validating it found

**2026-08-04. Built, kind-validated, PRs open, NOT merged, NOT in prod.**

The headline is not the sweep. It is that the negative control **failed on the
first run**, for a reason worth more than the feature: at a 120-second grace it
terminated 30 executions that had run every single step successfully and were
still inside the orchestrator's finalization tail. That tail is now measured in
two load regimes, and the measurement is baked into the code as a hard floor.

---

## 1. What was built

| Piece | Where | Default | PR |
| :-- | :-- | :-- | :-- |
| Non-convergence sweep | `noetl-server` `handlers/nonconvergence_sweep.rs` | **OFF** (`NOETL_NONCONVERGENCE_SWEEP_ENABLED`) | [server#298](https://github.com/noetl/server/pull/298) |
| Grace floor `MIN_NONCONVERGENCE_GRACE_SECS = 3600` | `noetl-server` `config/app.rs` | enforced at startup | server#298 |
| `execution.cancelled` recognised as a cancellation terminal | `noetl-server` `services/execution.rs` | always on, bug fix | server#298 |
| `pending_callback` marker on `command.completed` | `noetl-worker` `executor/command.rs` | always on, additive | [worker#214](https://github.com/noetl/worker/pull/214) |

### The predicate — progress, not shape

Eligible only when **all** hold. Separate `AND`s; no scoring, no "two of three":

1. started, and no terminal event (`playbook.completed|failed|cancelled`, both spellings);
2. **watermark stale** — the newest event of *any* type is older than the grace period;
3. no **live** worker holds an outstanding `command.claimed` (#171's guard, reused, not relaxed);
4. not parked awaiting an external callback (positive marker, §5);
5. not already carrying `execution.cancelled`;
6. no event carries `status='FAILED'` — the list projection already reports those as FAILED (78 on prod), so terminating one would make the two views disagree;
7. **not a child whose parent is still progressing** (§6).

Terminal is the real one: `emit_event` → `playbook.failed` through the #103
chokepoint, so #118 idempotent-terminal dedup holds and two replicas racing one
execution collapse to a single terminal. `meta.reason =
watermark_stalled_beyond_grace`. Nothing fabricated, nothing re-queued, no row
updated or deleted.

---

## 2. ⚠ The negative-control failure, and the fix it produced

**Run 1, `grace=120s`, under continuous load.**

| control | result |
| :-- | :-- |
| PC — 6 planted non-convergent executions | **6/6 terminated** ✓ |
| NC-terminal — 5 completed before the sweep | **5/5 untouched** ✓ |
| NC-load — healthy traffic during the sweep | **30 of 344 terminated** ✗ |

The 30 were not orphans. Their chains are complete:

```
16:57:45.881  playbook_started
16:57:46.610  command.completed  start      success
16:58:28.377  command.completed  test_step  success
17:03:14.916  command.completed  end        success     <-- every step done
17:05:20.968  playbook.failed    playbook   FAILED      <-- the sweep, 126s later
```

### How long it should have waited — and why one number is not enough

Time from the final step's `command.completed` to `playbook.completed`, sweep
OFF, no restarts:

| load regime | samples | finalized | p50 | p90 | max |
| :-- | --: | --: | --: | --: | --: |
| light sustained (1 execution / 6s) | 212 | 212 | **49s** | 75s | **138s** |
| behind a draining burst | 40 | 40 | **206s** | 210s | **393s** |

Two things matter here:

- **Nothing is lost in either regime.** Every execution finalized. The tail is
  minutes long, not infinite.
- **The tail is ~8× longer under load**, because it scales with drive-queue
  depth (kind runs a single system-pool replica under
  `NOETL_STATE_BUILDER=offserver`, so every hop of every execution serialises
  through one worker).

That spread is the real argument. A grace picked on a quiet cluster is wrong on
a busy one, and busy is exactly when the sweep would fire.

### The fix

`MIN_NONCONVERGENCE_GRACE_SECS = 3600`, applied in `effective_grace_secs()` at
**both** the startup-log site and the query site, so the number an operator
reads is the number the predicate uses. A lower configured value is **raised**,
loudly, not honoured. Verified live in kind:

```
non-convergence sweep: NOETL_NONCONVERGENCE_GRACE_SECS is below the safe floor
and has been RAISED …  configured=120 effective=3600
non-convergence sweep: ENABLED …  grace_secs=3600
```

- 3600s is **9×** the worst observed tail, **26×** the light-load one.
- The 86400s default is **220×**.
- Costs the real use case nothing: the prod backlog is 3.5–159 **days** stale.

Three unit tests pin it. **This is the value of running the negative control
under load rather than reasoning about it** — the predicate was correct
throughout; the safety margin was not.

---

## 2a. The `execution.cancelled` fix carries no risk to live work

The same image makes `ExecutionService` recognise `execution.cancelled` as a
cancellation terminal — which also makes `is_cancelled()` return true for those
executions, and workers poll that to decide whether to abort. Worth checking
before it ships, since "a read-path fix" that aborts running work would not be
one.

Measured on prod:

| | |
| :-- | --: |
| executions carrying `execution.cancelled` | **234** |
| active in the last 24h | **0** |
| active in the last 30 days | **0** |
| newest one, last event | **59 days ago** |

Every one is long dead and was deliberately cancelled. The fix flips them
`RUNNING` → `CANCELLED` in the projection and writes no events.

---

## 3. The backlog is historical debt, not an active leak

Measured on the same rig: of the load executions older than 10 minutes,

```
finalized = 148 / 148     permanent-stall rate = 0.0%
```

Nothing in kind stalls permanently. So the sweep is not papering over an ongoing
bug — prod's 3359 came from historical conditions (the migration, NATS-era
breakage, the #227 rehydrate defect that worker#213 fixed), and a drain is a
one-time cleanup rather than a recurring chore.

---

## 4. Positive control: produced through the real API

Not by writing rows. `POST /api/execute` accepts `execution_pool`, routing
commands to `noetl.commands.<pool>.<eid>` while workers subscribe to
`noetl.commands.shared.>`. Firing with `execution_pool: "nc227-void"` yields a
genuinely issued, genuinely never-claimed command:

```
16:50:24.730 playbook_started  fixtures/playbooks/hello_world  STARTED
16:50:24.733 command.issued    start                           PENDING
                    <-- nothing, ever
```

That is prod's "command.issued, never claimed" shape (33 executions), reproduced
without touching the database.

---

## 5. The sharpest edge: callbacks

On the `pending_callback` path the worker skips its own `call.done` and returns,
freeing the slot. From the event log a healthy execution parked on a six-hour
callback is **indistinguishable** from one whose DAG ran out of successors —
both have a `command.completed`, no outstanding claim, and an arbitrarily old
watermark. Condition 3 does not save it, because there is no claim.

So the worker stamps `pending_callback: true` onto that `command.completed`, and
the sweep excludes on that **positive signal**. A missing or malformed marker
reads as "not parked", never as "parked", and the comparison is textual so a bad
value cannot take a tick down with a cast error.

Verified against prod rows rather than assumed: the payload lands in
**`result.context`**, not the `context` column (NULL on every `command.completed`
on prod). The predicate checks all three plausible locations.

**Coverage limit, stated plainly:** the end-to-end container-callback path was
**not** exercised. `Tool::Container` is its only producer and is effectively
unused — prod has **zero** events mentioning `pending_callback` and one
mentioning a container job handle (#186). Assurance here is unit tests plus the
SQL reading the marker directly.

---

## 6. Children of live parents

**2919 of the 3258 eligible executions on prod are children**, and 165 have a
parent that is itself non-terminal. A parent mid-flight may still drive the
child it is waiting on — terminating it would be failing work another live
execution owns, the same mistake the live-claim guard prevents one level up.

Zero eligible executions have a parent that emitted anything in the last 24h, so
the guard is **inert against today's backlog**: it terminates exactly the same
set. It is also **strictly narrowing** — it can only move a candidate from
Terminate to Skipped — so it cannot invalidate a negative control taken without
it. Cost: **418ms vs 408ms** warm, a 2.5% overhead every 300s.

---

## 6a. Running alongside #171, which is already ON in prod

`NOETL_ORPHAN_SWEEP_ENABLED=true` on prod today, so both sweeps will run
together. Their candidate sets **can** overlap: my predicate terminates a
dead-worker-held claim too, and #171 exists for exactly that shape.

Two things make that safe:

- **The overlap is empty on today's data.** #171's candidate scan is bounded to
  a 48h lookback and my grace is 24h, so the only executions both can see are
  those stale between 24h and 48h with a dead-worker claim. The youngest eligible
  execution on prod is **3.57 days** old, so #171 cannot see a single one of
  them.
- **A collision is handled anyway.** Both terminate through
  `handlers::event_write::emit_event`, where the `FinalizedGuard`
  (`state.rs:594`, ai-meta#118) enforces exactly one terminal per execution —
  `mark()` returns true for the first and false for every later one, which is
  dropped *before* the chain linker so it cannot fork the chain. A suppressed
  duplicate increments `terminal_dedup{suppressed}` rather than failing silently.

The guard is in-memory and process-local (bounded FIFO, 8192), so it is a
single-replica net; prod runs one server replica and execution affinity
serialises finalize to the owner regardless.

---

## 6b. Paired evidence — including one number that looks alarming and is not

Collected from the writer's metrics faces via `127.0.0.1` (never `localhost` —
`::1` resolves and refuses, giving empty output that reads as zero), and never
by bare-connecting `:9104`/`:9107`/`:9108` (ehdb#311: one bare connect
permanently kills that face).

| signal | value |
| :-- | --: |
| `ehdb_events_group_committed` — all three groups | **15240, identical** |
| `ehdb_events_group_lag` — all three groups | **0** |
| `ehdb_events_cursor_errors` | **0** |
| `ehdb_l0_out_of_order_appends` | **0** |
| `noetl_ehdb_events_publish_errors_total` | **0** (absent) |
| healthy load executions wrongly failed | **0 of 308** |

**The one that needed chasing:** `ehdb_feed_shard_lag{shard="0"}` read **5680
and rising**, with `ehdb_feed_shard_committed` **frozen at 3265** across three
20s samples — while executions were completing normally.

That is not a defect, and the per-subject breakdown says why:

```
ehdb_feed_subject_lag{subject="commands.shared.shard.0"}       0    <- the user pool
ehdb_feed_subject_lag{subject="commands.system.shard.0"}       44
ehdb_feed_subject_lag{subject="commands.nc227-void.shard.0"}    7    <- my positive controls
ehdb_feed_subject_lag{subject="commands.nc227-void2.shard.0"}  12    <- my positive controls
```

The positive controls are, by construction, commands no consumer will ever
claim. A consumer group's committed cursor is the **acked prefix**, so 19
never-acked records pin the whole-shard cursor and its aggregate lag grows
forever. The real pool's own subject is at **lag 0**.

This is exactly the isolation [ehdb#303](https://github.com/noetl/ehdb/pull/303)
added for #194 — the autoscaler triggers on `ehdb_feed_subject_lag`, not the
shard aggregate, precisely so one stuck command cannot pin a pool at max
replicas. The test reproduced the condition by accident and confirms the
isolation holds.

⚠ **Operational consequence: do not use the `execution_pool`-void technique on
prod.** It creates permanently unacked records that pin the shard's committed
cursor and inflate its aggregate lag for the life of the log. It is a fine
positive control in kind, where the cluster is disposable.

---

## 6c. One known limit: the `catalog_id` fallback would fail the insert

The candidate query resolves `catalog_id` from the execution's first event
carrying a non-zero one, with `COALESCE(..., 0)` as a fallback — inherited
verbatim from #171's orphan sweep.

`noetl.event` carries `event_catalog_id_fkey FOREIGN KEY (catalog_id) REFERENCES
catalog(catalog_id)`, so if that fallback ever fired the `playbook.failed` insert
would violate the FK. The failure is contained — `emit_nonconvergent_failed`
returns `Err`, the tick logs it and increments
`noetl_nonconvergence_sweep_total{outcome="error"}`, and the loop continues — but
that execution would be retried and fail every tick, never terminating.

Checked rather than assumed: **0 of the 3258 eligible prod executions** resolve
to `catalog_id = 0`. Every one has a resolvable catalog. The fallback is
unreachable on today's data, and this is pre-existing shared behaviour with
#171 rather than something this change introduces — recorded so a rising
`outcome="error"` has a first place to look.

---

## 7. What it deliberately does not do

The brief asked to distinguish "held by a live worker but provably stuck" from
"held by a live worker and progressing". **That is not provable today.** The only
per-command progress signal that ever existed is `command.heartbeat`, emitted by
the retired Python worker — the newest on prod is dated **2026-05-23**, and the
Rust worker emits none. `noetl.runtime` liveness is pool-level, not
command-level.

Rather than dress a timeout up as a proof, the timeout is exposed as
`NOETL_NONCONVERGENCE_STUCK_CLAIM_SECS`, **default 0 = off**, and documented as a
timeout. Reinstating a per-command progress signal is the honest prerequisite,
and this is the one place the design is knowingly weaker than the brief asked.

### Idempotent re-issue (brief part 4) — not built, and why

The sweep **terminates rather than re-queues**, so it re-executes nothing and
creates none of the risk part 4 addresses.

Investigating what exists produced a sharper finding, now
[#228](https://github.com/noetl/ai-meta/issues/228): today's protection is
`orchestrate-core` folding `command.issued` into `StepState::CommandIssued`
(`state.rs:611`) — **state-derived, not key-derived**. `noetl.command`'s PK is
`(execution_id, command_id)` and `command_id` embeds the issuing event id, so a
re-issue mints a different id and collides with nothing. The guard therefore
provides no protection in exactly the situation where state cannot be rebuilt —
which is the situation that causes re-issue, and precisely what #227 was. The
two failure modes are perfectly correlated.

That belongs on the re-issue path, not in this sweep.

---

## 8. Performance

Nothing added to publish, append, claim, ack or dispatch. Background task,
default 300s interval.

Candidate-first in the #62 shape: `starts` selects from the `event_type` index
(~11k start events, not the 966k-row table), the terminal check rides
`idx_event_exec_type`, and watermark / claim / callback / parent are `LATERAL`
probes on an already-bounded set.

Measured against the **real prod table** (966,493 rows, partitioned), read-only:

```
Planning Time:   30-76 ms
Execution Time:  408 ms  (without the parent guard)
                 418 ms  (with it)
```

No sequential scan on any large partition. At 300s that is a **0.14% duty
cycle** on one connection.

---

## 9. Predicate dry-run against real prod data (read-only)

| check | result |
| :-- | --: |
| eligible at grace 24h, unbounded scan | **3258** |
| the 3 `execution.cancelled` muno runs (must be excluded) | **0** ✓ |
| already-`status='FAILED'` executions excluded | **78** ✓ |
| children of an *active* parent (would be skipped) | **0** |
| `awaiting_callback` | 0 (no markers exist yet) |
| youngest eligible | **3.57 days** stale |
| oldest eligible | **158.9 days** stale |

The youngest eligible row being 3.57 days old against a 24h grace is a **3.6×
margin at the tightest point**.

---

## 10. Status and what is owed

- Server: `feat/227-nonconvergence-sweep`, **705/705** lib tests, clippy clean.
- Worker: `feat/227-pending-callback-marker`, 556/556 lib tests.
- Both **default-off**; rollback is the flag, no state carried between ticks.

**The prod drain has NOT been run**, and cannot be from this session: it needs
server#298 merged, released, built and rolled to prod, and **PR merges are gated
to a human here**. The drain procedure is otherwise mechanical — see
`PROD-DRAIN.md`.

Scripts: `nc-validate.sh` (positive control via `execution_pool` routing to a
segment no worker serves), `nc-perf.sh` (flag off/on arms).
