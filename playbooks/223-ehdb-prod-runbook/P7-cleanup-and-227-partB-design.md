# Part A — test executions cleared; Part B — design, and a blast-radius finding

**2026-08-04. Part A done on prod. Part B NOT built.**

---

# Part A — 23 synthetic executions cancelled via the platform's own API

## The mechanism used

`POST /api/executions/{execution_id}/cancel` → `ExecutionService::cancel`, which:

- refuses if the execution is already `COMPLETED` / `FAILED` / `CANCELLED`,
- resolves `catalog_id`, mints an `event_id` from the server's snowflake
  generator,
- and writes the cancellation **through the CQRS write-path chokepoint**
  (ai-meta#103) — the same emit path every other terminal event uses.

That is the platform's real state machine emitting `playbook.cancelled`.
**No event was hand-written.**

## Safety gate, run before anything was cancelled

Prod holds **93** `RUNNING` executions — not 23. Only 23 were mine.

| Check | Result |
| :-- | :-- |
| Target count | 23 |
| All `vars_test/test_vars_block` | yes — 0 non-test rows |
| Overlap with the not-mine set | **0** |

The other **70 are pre-existing and were not touched**. They are not all
fixtures: the sample includes `system/scheduled_cleanup` and a real
**`muno/playbooks/itinerary-planner` from 2026-06-25**. Cancelling by a broad
predicate would have hit real work — which is why this was scoped to an explicit
ID list.

## Before / after

| | before | after |
| :-- | --: | --: |
| RUNNING | 93 | **70** |
| CANCELLED | 11 | **34** |
| COMPLETED | 4874 | 4874 |
| FAILED | 22 | 22 |

- My 23 → **all `CANCELLED`**.
- The 70 not-mine → **all still `RUNNING`, 0 changed state**.
- `COMPLETED` and `FAILED` totals unchanged — nothing else was disturbed.

Full ID list and per-call responses: `scratchpad/cancel-log.txt` (session-local).
Reversible in the sense that matters: the cancellation is an append-only event,
the prior history is intact, and no data was deleted.

---

# Part B — design, and why it is not built yet

**Not implemented.** What follows is the design plus one finding that materially
changes its blast radius and should be settled before code is written.

## ⚠ The finding: 70 pre-existing stuck executions, and some are real

A non-convergence sweep does not get to see only my test data. On prod today it
would evaluate **70 executions**, including:

- a **`muno/playbooks/itinerary-planner` RUNNING since 2026-06-25** — a real
  user-facing business execution, 40 days stalled,
- a **`system/scheduled_cleanup`**,
- ~68 `fixtures/playbooks/hello_world` from earlier soaks and the IaC's own
  verify bursts.

The muno one is the case that matters. It is almost certainly genuinely dead —
but it is **not test data**, and terminating a real business execution is a
different act from terminating a fixture. Whatever predicate ships will make
that call automatically, so the question "what should happen to a 40-day-old
real execution?" needs a human answer before the predicate is written, not
after.

This also means the sweep cannot be validated only against synthetic load: its
first prod run has a 70-execution backlog with mixed provenance.

## Eligibility predicate (proposed)

Terminate only when **all** hold:

1. **Provably unrecoverable**, not merely slow — the drive reports the
   post-#213 `rehydrate{outcome="incomplete"}` (rehydrate ran, replayed the
   retained feed, and the chain still does not resolve). `empty` no longer
   occurs; `incomplete` is the real signal, and it is only reachable after a
   successful subscribe.
2. **No forward progress** — the execution's chain head watermark is unchanged
   for ≥ `non_convergence_grace_secs`. This is the signal that distinguishes
   "held by a live worker and progressing" from "held by a live worker and
   provably stuck", which heartbeat presence alone cannot.
3. **Bounded attempts** — ≥ N consecutive unrecoverable drive attempts.
4. **Beyond retention** — the gap is older than the events feed's retention
   floor, so no future replay can fix it.

The existing #171 guard stays exactly as it is for the orphan case. This is an
*additional* condition, not a relaxation of that one.

## Terminal transition

Reuse the #171 orphan-sweep emission path verbatim: `emit_event` →
`playbook.failed`, append-only, idempotent-terminal, rate-limited per tick, with
a machine-readable reason (`chain_gap_beyond_retention`). No new terminal path.

## Idempotent re-issue (part 4)

Dedup re-drives on `(execution_id, step, attempt)` at the point the server
re-issues, so a re-issue cannot race the bus's own redelivery into a double
execution — the secondary defect observed in the #227 analysis (a step executed
twice after a restart).

## Performance

The hard requirement is zero synchronous per-command / per-append cost:

- Detection is a **periodic sweep**, off the hot path, exactly like #171 —
  interval and per-tick cap configurable.
- The progress signal is a **watermark comparison**, not a scan.
- Nothing is added to publish, append, claim or ack.
- Proof obligation: hot-path publish/append throughput and dispatch p50/p99
  measured before and after with the flag both off and on, showing no
  regression. The #205 harness is the right instrument.

## Safety

Off by default behind its own flag (`NOETL_NONCONVERGENCE_SWEEP_ENABLED`),
mirroring `NOETL_ORPHAN_SWEEP_ENABLED`. Negative controls must prove it never
terminates a healthy progressing execution under load — including the case that
matters most: an execution whose step is legitimately slow.

## Why it is not built

This is a server-side change with a real blast radius, and doing it properly
needs: the predicate implemented against live watermark signals, a kind rig with
paired-evidence load, before/after perf numbers, and negative controls. That is
a substantial piece of work, and starting it and leaving it half-finished on a
branch would be worse than not starting.

The blast-radius finding above should also be settled first — the predicate's
correct behaviour on a 40-day-old real execution is a product decision, not an
implementation detail.
