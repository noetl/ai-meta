# #227 part B — the non-convergence sweep, and what validating it found

**2026-08-04. Built, kind-validated, NOT in prod.**

The headline is not the sweep. It is that the negative control **failed on the
first run**, for a reason worth more than the feature: at a 120-second grace the
sweep terminated 30 executions that had run every single step successfully and
were still inside the orchestrator's finalization tail. That is now measured,
and the measurement is baked into the code as a hard floor.

---

## 1. What was built

| Piece | Where | Default |
| :-- | :-- | :-- |
| Non-convergence sweep | `noetl-server` `src/handlers/nonconvergence_sweep.rs` | **OFF** (`NOETL_NONCONVERGENCE_SWEEP_ENABLED`) |
| `pending_callback` marker on `command.completed` | `noetl-worker` `src/executor/command.rs` | always on, additive |
| `execution.cancelled` recognised as a cancellation terminal | `noetl-server` `src/services/execution.rs` | always on, bug fix |
| Grace floor `MIN_NONCONVERGENCE_GRACE_SECS = 3600` | `noetl-server` `src/config/app.rs` | enforced at startup |

### The predicate

Progress, not shape. Eligible only when **all** hold:

1. started, and no terminal event (`playbook.completed|failed|cancelled`, both spellings);
2. the newest event of *any* type is older than the grace period — the watermark has stopped;
3. no **live** worker holds an outstanding `command.claimed` (#171's guard, reused, not relaxed);
4. not parked awaiting an external callback (positive marker, §4);
5. not already carrying `execution.cancelled`;
6. no event carries `status='FAILED'` — the list projection already reports those as FAILED (78 on prod), so terminating one would make the two views disagree.

Terminal transition is the real one: `emit_event` → `playbook.failed`, append-only,
through the #103 chokepoint, so #118 idempotent-terminal dedup holds and two
replicas racing one execution collapse to a single terminal. `meta.reason =
watermark_stalled_beyond_grace`. Nothing is fabricated, nothing is re-queued, no
row is updated or deleted.

---

## 2. ⚠ The negative-control failure, and the fix it produced

**Run 1, `grace=120s`, under continuous load.**

| control | result |
| :-- | :-- |
| PC — 6 planted non-convergent executions | **6/6 terminated** ✓ |
| NC-terminal — 5 completed before the sweep | **5/5 untouched** ✓ |
| NC-load — healthy traffic during the sweep | **30 of 344 terminated** ✗ |

The 30 were not orphans. Their event chains are complete:

```
16:57:45.881  playbook_started
16:57:46.610  command.completed  start      success
16:58:28.377  command.completed  test_step  success
17:03:14.916  command.completed  end        success     <-- every step done
17:05:20.968  playbook.failed    playbook   FAILED      <-- the sweep, 126s later
```

Every step succeeded. The execution was waiting for the orchestrator to emit
`playbook.completed`, and the sweep did not wait long enough.

### How long *should* it have waited — measured, not guessed

Sweep OFF, no restarts, 40 `hello_world` executions. Time from the final step's
`command.completed` to `playbook.completed`:

| | |
| :-- | --: |
| finalized | **40 / 40** |
| never finalized | **0** |
| p50 | **206s** |
| p90 | **210s** |
| max | **393s** |

So finalization is completely reliable — it just takes about three and a half
minutes. A 120-second grace sits *inside* that tail, which is exactly why it ate
healthy work. (An intermediate reading taken at t+300s showed "40/40 still
RUNNING" and briefly looked like a finalization bug; polling to t+600s showed it
is a slow tail, not a loss. Worth recording because the wrong version of that
observation would have sent this in the wrong direction.)

### The fix

`MIN_NONCONVERGENCE_GRACE_SECS = 3600`, enforced in
`effective_grace_secs()` at both the startup-log site and the query site, so the
number an operator reads is the number the predicate uses. A lower configured
value is **raised**, loudly, not honoured.

- 3600s is a **9× margin** over the observed maximum (393s).
- The 86400s default is a **220× margin**.
- It costs the actual use case nothing: the prod backlog is 3.5–159 **days** stale.

Three unit tests pin it (`grace_below_the_floor_is_raised`,
`grace_at_or_above_the_floor_is_honoured`, `default_grace_clears_the_floor`).

**This is the value of running the negative control under load rather than
reasoning about it.** The predicate was correct throughout; the safety margin was
not, and only a live run at an aggressive setting exposed the difference.

---

## 3. Positive control: how it was produced

Not by writing rows. `POST /api/execute` accepts `execution_pool`, which routes
the execution's commands to `noetl.commands.<pool>.<eid>`; workers subscribe to
`noetl.commands.shared.>`. Firing with `execution_pool: "nc227-void"` produces a
genuinely issued, genuinely never-claimed command through the real API:

```
16:50:24.730 playbook_started  fixtures/playbooks/hello_world  STARTED
16:50:24.733 command.issued    start                           PENDING
                    <-- nothing, ever
```

That is prod's "command.issued, never claimed" shape (33 executions), reproduced
without touching the database.

---

## 4. The sharpest edge: callbacks

On the `pending_callback` path the worker skips its own `call.done` and returns,
freeing the slot while an external system works. From the event log a healthy
execution parked on a six-hour callback is **indistinguishable** from one whose
DAG ran out of successors — both have a `command.completed`, no outstanding
claim, and an arbitrarily old watermark. The live-claim guard does not help,
because there is no claim.

So the worker now stamps `pending_callback: true` onto that `command.completed`,
and the sweep excludes on that **positive signal** — never on an inference; a
missing or malformed marker reads as "not parked", never as "parked", and the
comparison is textual so a bad value cannot take a sweep tick down with a cast
error.

Verified against prod rows rather than assumed: the worker's payload lands in
**`result.context`**, not the `context` column (which is NULL on every
`command.completed` on prod). The predicate checks all three plausible
locations.

Coverage limit, stated plainly: the end-to-end container-callback path was **not**
exercised in kind. `Tool::Container` is its only producer and it is effectively
unused — prod contains **zero** events mentioning `pending_callback` and one
mentioning a container job handle (see #186). The exclusion is covered by unit
tests (`callback_parked_execution_is_never_terminated`,
`callback_check_outranks_dead_worker`) and by the SQL being read straight from
the marker. That is the honest level of assurance today.

---

## 5. What it deliberately does not do

The ask included distinguishing "held by a live worker but provably stuck" from
"held by a live worker and progressing". **That is not provable today.** The only
per-command progress signal that ever existed is `command.heartbeat`, emitted by
the retired Python worker — the newest one on prod is dated **2026-05-23**, and
the Rust worker emits none. `noetl.runtime` liveness is pool-level, not
command-level, so it cannot answer the question either.

Rather than dress a timeout up as a proof, the timeout is exposed as
`NOETL_NONCONVERGENCE_STUCK_CLAIM_SECS`, **default 0 = off**, and documented as a
timeout. Reinstating a per-command progress signal is the honest prerequisite,
and is the one place this design is knowingly weaker than the brief asked for.

---

## 6. Performance

Nothing was added to publish, append, claim, ack or dispatch. Detection is a
background task on its own interval (default 300s).

The candidate query is candidate-first in the #62 shape — `starts` selects from
the `event_type` index (~11k start events, not the 966k-row table), the
terminal-existence check rides `idx_event_exec_type`, and the watermark / claim /
callback lookups are `LATERAL` probes on an already-bounded set.

Measured against the **real prod table** (966,493 rows, partitioned), read-only:

```
Planning Time:   29.9 ms
Execution Time: 408.8 ms   (warm; 395.5 ms on repeat)
```

No sequential scan on any large partition. At the 300s default interval that is a
**0.13% duty cycle** on one connection.

---

## 7. Predicate dry-run against real prod data (read-only)

The exact SQL, run against prod without writing anything:

| check | result |
| :-- | --: |
| eligible at grace 24h, unbounded scan | **3258** |
| the 3 `execution.cancelled` muno runs (must be excluded) | **0** ✓ |
| already-`status='FAILED'` executions excluded | **78** ✓ |
| `awaiting_callback` | 0 (no markers exist yet) |
| youngest eligible execution | **3.57 days** stale |
| oldest eligible execution | **158.9 days** stale |

The youngest eligible row being 3.57 days old against a 24h grace is a **3.6×
margin at the tightest point** — the prod backlog is nowhere near the boundary.

---

## 8. Status

- Server: `feat/227-nonconvergence-sweep`, 701/701 lib tests green, clippy clean.
- Worker: `feat/227-pending-callback-marker`, 556/556 lib tests green.
- **Not in prod. Not merged.** Default-off in both.
- The prod drain has **not** been run.

### Re-validation still owed before any prod drain

Run 1 is superseded by the floor. What must be re-run at a production-realistic
grace (≥3600s, ideally the 86400s default) before prod is touched:

1. sweep enabled at the default grace against kind's genuinely days-stale backlog;
2. continuous load throughout, asserting **zero** healthy executions terminated;
3. paired evidence via `playbooks/220-ehdb-only-kind-soak/soak.sh` —
   published == projected == all group cursors, lag 0, 0 dup / gap /
   out-of-order / cursor_errors;
4. `nc-perf.sh` before/after arms for the hot-path numbers.

Scripts: `nc-validate.sh`, `nc-perf.sh` in this directory.
