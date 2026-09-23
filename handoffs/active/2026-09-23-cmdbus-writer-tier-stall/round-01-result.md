---
thread: 2026-09-23-cmdbus-writer-tier-stall
round: 1
from: claude
to: dispatcher
created: 2026-09-23T07:15:00Z
status: partial
tracks: noetl/ai-meta#351
---

# Phase B — verdict: **RE-DRIVES**. `#351` is a `#315` defect fix, not a capacity fix.

Scope run: **Phase B only, read-only.** Phase A (the wiki push) was not run — it
is a write, and this round was dispatched read-only. Phase C was not run; the
wait phrase has not been said.

## The answer

The ~19 cmd/min are **not legitimate work**. They are re-drives of a small,
fixed set of stuck executions that can never reach a terminal state. Every
measurement below is mine, taken 2026-09-23 06:39–07:12Z; none is inherited.

**Do not add pool capacity.** At the measured rates it would close the gap and
leave the loop running invisibly.

## The evidence that settles it

### 1. 100% of the work is a no-op that asks to be re-driven

60-minute windows, both system-pool pods (they carry **different `app` labels** —
each queried by pod name):

| pod | drives | no-ops | did real work |
| :-- | --: | --: | --: |
| `…system-pool-…-sfk8r` | 412 | **412** | **0** |
| `…system-pool-shard1-…-zxbzl` | 413 | **413** | **0** |

The log line is explicit, and it names the mechanism itself:

```
off-server drive (stateless): WAL chain incomplete; returning no-op,
server reconcile will re-drive execution_id=…
```

### 2. The same executions recur — 43 of them, for hours

895 drive mentions in 60 minutes resolve to **43 distinct `execution_id`s**,
each re-driven **28–36 times per hour**.

### 3. No new execution ever enters the set

Ages decoded from the snowflake ids (shift 22; epoch derived as
**2024-01-01T00:00:04Z** by anchoring on `361040249960275968`, observed being
created at 06:45:07.7Z — a sane epoch is itself a check on the decoding, and the
API's `started_at` for three sampled ids matched the decoded ages exactly):

| age | count |
| :-- | --: |
| < 1 h | **0** |
| 1–6 h | 5 |
| 6–24 h | 35 |
| > 24 h | 3 |

Median **14.8 h**, oldest **27.8 h**. A workload with no arrivals and no
departures is not work; it is a loop.

### 4. The drives make no progress and never age

- `step=__orchestrate__` on **480 of 483** drives — always the same step.
- `attempts=0` on **483 of 483**. The attempt counter never increments.

### 5. Some are already terminal and are re-driven anyway

All 43 resolved via `GET /api/executions/{id}`:

| | |
| :-- | --: |
| `RUNNING` (for 6–28 h, zero progress) | 36 |
| `FAILED` | 6 |
| `COMPLETED` | 1 |
| **non-null `completed_at` — terminal, still re-driven** | **4** |

⚠ `status` may be the frozen Python-era column (noetl/ai-meta#235), so I do not
lean on it. `completed_at` and the behavioural evidence above are independent of
it.

Five playbooks, so this is a generic re-drive defect and not one bad playbook:
`saqbit/playbooks/qaoa-maxcut` 26, `automation/agents/mcp/hotelbeds` 7,
`muno/playbooks/hotel-cards` 5, `system/scheduled_cleanup` 4,
`muno/playbooks/profile` 1.

⚠ Note `system/scheduled_cleanup` ×4 — genuinely periodic system work is in
here, but it is **stuck in the same loop**, not being completed.

### 6. The server attributes the load to retries itself

Deltas over 700 s (06:56:34 → 07:08:14), `noetl_orchestrate_drive_total`:

| stage | /min |
| :-- | --: |
| `event_suppressed` | 55.5 |
| `dispatched` | 26.1 |
| `dispatched_offserver_stateless` | 20.7 |
| **`offserver_retry`** | **15.9** |
| `expired` | 6.6 |
| `applied` + `applied_stateless` | 4.5 |

Of 26.1 dispatches/min, **15.9 are explicitly retries** and only 4.5 apply
anything. `in_flight_stale_executions` rose **10 → 13** inside the same window.

### 7. User work is genuinely zero, and the backlog is worse than reported

| | 06:56:34Z | 07:08:14Z | rate |
| :-- | --: | --: | --: |
| `feed_subject_lag{commands.shared.shard.0}` | 0 | 0 | **+0.00/min** |
| `feed_subject_lag{commands.system.shard.0}` | 4912 | 4995 | **+7.11/min** |
| `ehdb_feed_shard_committed` | 122784 | 123011 | 19.5/min |
| `ehdb_l0_appends` | 22718 | 23028 | 26.6/min |

`commands.shared` is still flat 0 — the handoff's headline claim holds. The
system backlog has grown **606 → 4995** since 19:18 yesterday, and is now
accumulating at **+7.1/min**, not the +1.46/min previously measured. The drain
shortfall is wider than 7.5%, which makes the capacity temptation stronger and
the defect no less real.

## Why the existing cap does not save it

`noetl_reconcile_giveup_total{reason="max_noops"}` moved **109 → 111** — about
**0.17/min against 15.9 retries/min**, roughly two orders of magnitude too slow
to drain the set.

⚠ **Hypothesis, not measured:** `attempts=0` on every single drive suggests each
re-drive is presented as a *fresh first attempt*, so a per-attempt cap can never
accumulate toward its limit. I did not read the reconcile code, so this is the
next thing to check, not a finding.

## What I could not measure

`orch_cache` size is **not exposed as a metric** on the server (`3.112.5`); I
searched the full 899-line `/metrics`. So noetl/ai-meta#315's "unbounded
orch_cache growth" is **not directly observable in production today** — the
verdict above rests on drive counters and execution recurrence instead. That
observability gap is worth closing on its own terms.

## Method notes

- `port-forward` **fails open** — a bound local port routes `curl` to whatever
  owns it. Every sample re-established its own forward on a distinct port and
  ran a **negative control**: with the forward killed, the same probe must fail.
  All samples passed; none is a cross-cluster read.
- ANSI colour codes were stripped before every `grep` over `kubectl logs`
  (a bare `grep " ERROR "` is a known false zero here).
- The two system-pool pods were addressed **by pod name**, not by an `app`
  selector, per the handoff's trap (b).

## Recommendation

Treat noetl/ai-meta#351 as a **noetl/ai-meta#315 defect fix**. Do not size a
pool. The next step is to establish why a re-drive presents as `attempts=0` and
why a terminal execution (`completed_at` set) is re-driven at all.
