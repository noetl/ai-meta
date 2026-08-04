# P2 — prod soak: ABORTED in the first regime, on a live prod defect

**Run 2026-08-04 (02:21–02:30 UTC) against `shastaratech-noetl-prod`, on worker
v5.92.0. Stopped at the first regime and NOT resumed. P4 is NOT clear.**

The soak did not fail a latency or durability gate. It never got far enough to
measure one. The first 12-execution unsaturated regime revealed that **the
events-side consumers had already been wedged for three and a half hours**, and
every health signal said otherwise.

## The finding

`noetl.event` — the platform's append-only source of truth — **had received no
writes since 23:03 UTC**, a 3h24m gap ending only because load was applied and
made it visible.

| Signal | Value | |
| :-- | :-- | :-- |
| `ehdb_events_group_committed` (all three groups) | **frozen at 3137** for the entire 642 s sample window | ❌ |
| `ehdb_events_group_lag` | rose to **24** and stayed there, 88.8% of samples > 0 | ❌ |
| `materializer_drained_total` (system pool) | **36**, unchanged — exactly P1's execution-#2 count | ❌ |
| `materializer_project_errors_total` | 0 | — |
| `ehdb_events_cursor_errors` | **0** throughout | ✅ |
| `ehdb_l0_out_of_order_appends` | **0** throughout | ✅ |
| `ehdb_feed_shard_lag` (commands) | 0 throughout | ✅ |
| `/healthz`, `/readyz` on the system pools | `ok`, `ready` | ⚠ **wrong** |
| Faces on the writer | all ten listening; 6 ESTABLISHED on `:9104`, 2 on `:9108`, 1 on `:9105` | ⚠ **connected but idle** |
| Last log line, every worker pool | **2026-08-03T23:03**, vs. wall clock 02:27 | ❌ |

The consumers are **connected and reporting healthy while consuming nothing**.
That is the same silent-failure class this whole workstream exists to eliminate
— and it is not any of the classes the runbook told us to watch for. There is
no loss, no duplication, no out-of-order append, and no cursor error.

## What the load actually did

12 executions of `vars_test/test_vars_block` were planned at concurrency 4
(under the 8-slot pool → unsaturated, the regime that measures the bus). Only
the first round of 4 was submitted before the anomaly was clear.

```
cmd_committed  39195 → 39199   (+4 — exactly ONE command per execution)
grp_committed   3137 →  3137   (frozen)
grp_lag             0 →    24  (frozen)
```

`+4` is the tell. In P1 a single execution of this playbook generated ~19
command records across its steps. Here each execution got its **first** command
issued and claimed, and then stopped. Under `NOETL_STATE_BUILDER=offserver` the
drive rebuilds state from the WAL fan-out face (`:9108`); with that consumer
parked, the drive cannot advance, so no second command is ever issued.

The four executions are stuck and were never visible through the API, because
`GET /api/executions/{id}` and `/api/ehdb/executions/{id}/events` both read the
**projection** tier, whose sole writer is the wedged materializer. They return
`404` and `exists: false` respectively — which looks like "the execution does
not exist" and is really "nothing has been projected since 23:03".

Stuck execution ids: `342854452903944192`, `342854453327568896`,
`342854453822496768`, `342854454367756288`.

## Why the state builder counters matter

Cumulative on each system pool since the P1 roll (~22:56):

```
state_builder_drive_builds_total{outcome="served"}               10
state_builder_drive_builds_total{outcome="fallback_incomplete"}   1
state_builder_drive_builds_total{outcome="stateless_retry"}       1
state_builder_drive_wait_total{outcome="timeout"}                 5
state_builder_builds_total{outcome="incomplete"}                  7
state_builder_wal_events_total                                 6264
materializer_drained_total                                       36
```

All of it accrued during P1's verification at ~23:03 and then stopped dead.
The `timeout: 5` / `incomplete: 7` counts were already non-zero *during* the P1
window, which is worth a second look — P1's executions completed, but the drive
was already waiting and timing out on WAL completeness while doing so.

## Timeline, and what did NOT cause it

| Time (UTC) | Event |
| :-- | :-- |
| 22:53 | writer rolled to v5.92.0; groups resumed `clamped=false`, execution COMPLETED |
| 23:00:45 | **controlled SIGTERM** (P1 seal proof) — both hosts sealed in 568 ms, cursors resumed exactly |
| 23:02:40 | replacement writer up, all faces up, all three groups resumed at 3103 |
| 23:03 | post-restart execution COMPLETED; groups advanced 3103 → 3137, **lag 0** |
| 23:03 → 02:21 | **3h18m idle. No traffic. No log lines from any pool.** |
| 02:21 | soak load applied → 4 commands claimed, 24 events appended, **nothing consumed** |

So the system was verifiably healthy *after* the P1 restart and consumed a full
execution to lag 0. The wedge developed during the idle window, not at the
restart. **The load did not cause it — the load revealed it.** Had the soak not
run, this would have surfaced as a user-facing outage the next time real traffic
arrived, with a dashboard full of green.

This also means P1's clean bill of health was accurate at the time it was
taken, and is not contradicted by this.

## What P2 was supposed to produce, and did not

| Objective | Status |
| :-- | :-- |
| 1. Throughput + dispatch latency at prod concurrency (p50/p99, append rate) | ❌ **not measured** — aborted in regime A |
| 2. `cursor_errors` at prod event rates | ⚠ **0 across 642 s**, but at a trivial event rate; not a prod-rate result |
| 3. KV + SSE under the gateway's real traffic | ❌ **not measured** — see below |
| 4. Hard-kill exposure bound (non-destructive) | ❌ **not measured** — see below |
| 5. Graceful writer restart under load | ❌ **not attempted** |

**On (3).** There was no organic user traffic in this window (~02:20 UTC), so
"the gateway's real traffic" could not be exercised. What was verified
read-only: the gateway holds an ESTABLISHED connection to the SSE face
(`10.119.1.75 → :9105`) and logged zero feed errors. It holds **no** connection
to the KV face `:9107`, which is expected — the KV client dials lazily and there
were no sessions. The KV path is therefore **unverified**, not broken. The
faces were never probed directly (ehdb#311).

**On (4).** The sampler produced `exposure = min(1024, lag)` with `max=24`,
`p99=24`, `>0` for 88.8% of samples — but **this number is meaningless as an
exposure bound.** It is a frozen backlog behind a stopped consumer, not the
lag distribution of a healthy system under load. Reporting 24 as "the prod
exposure bound" would be exactly the false-pass this rig is built to avoid. The
measurement has to be retaken once the consumers are healthy and real load is
flowing.

**The destructive SIGKILL variant (P2d) was not run and was not authorized.**

## Immediate state of prod

- Command bus: **functional** (`shard_lag 0`, commands claimed and acked).
- Events materialization: **stopped** since 23:03. `noetl.event` is not being
  written.
- Off-server state builder: **stalled**, so executions cannot advance past
  their first command.
- Four test executions stuck.
- No user impact observed *yet* — there is no traffic at this hour.
- Writer, server and gateway pods all Running, 0 restarts, all faces listening.

## Recommended remedy — NOT applied

The documented remedy for the analogous wedge (ai-meta#161, where a NATS bounce
wedged the system-pool state builder) is a rollout restart of the consuming
pools:

```bash
kubectl -n noetl rollout restart deploy/noetl-worker-system-pool-shard1
kubectl -n noetl rollout status  deploy/noetl-worker-system-pool-shard1
# then, once the backlog drains, the other pool:
kubectl -n noetl rollout restart deploy/noetl-worker-system-pool
```

Restarting **one** pool first is deliberate: the two are competing consumers on
the same groups, so a single restart should drain the 24-record backlog on its
own, which both restores the write path and **proves the diagnosis** (a
consumer-side park, not writer-side loss) while leaving the second pool wedged
as a control.

No data should be lost — the 24 records are durable in the EHDB feed and the
groups resume from their persisted cursor at 3137.

**This was attempted and blocked by the session's permission policy, and was
not worked around.** It needs explicit approval.

## Gate

**P2 FAILED to complete, and P4 is NOT clear.**

P4's Deployment→StatefulSet handover deliberately drops the writer pod and
depends on the consumers reattaching cleanly afterwards. Converging onto a
platform whose events consumers demonstrably stop consuming — silently, while
green — would make any post-converge anomaly indistinguishable from this defect.

Order of operations from here:

1. Restore the write path (restart, above) and confirm the backlog drains.
2. Root-cause the idle wedge; it is a new defect and needs its own issue.
3. Re-run P2 from the top on a healthy platform — none of its five objectives
   have usable results.
4. Only then reconsider P4.

---

# ADDENDUM — 2026-08-04 04:24–04:40 UTC: wedge cleared, root cause found, burst run, **new worse defect**

## 1. The wedge: root cause = half-open consumer connections (noetl/ai-meta#225)

Socket forensics captured **before** the restart, comparing client vs writer:

| | client conns on `:9104` | writer sees | |
| :-- | --: | --: | :-- |
| wedged pool `10.119.1.93` | **6** | **3** | ❌ 3 half-open |
| healthy pool `10.119.1.44` | 6 | 6 | ✅ |

Healthy is six per pool (three groups × two). The wedged pool re-established
only half after the 23:00:45 writer restart and kept three corpses —
ESTABLISHED client-side, absent writer-side, all queues `0/0`, so nothing ever
discovered the break.

**Why the command bus survived and the events feed did not:** #208 added TCP
keepalive + a negotiated coordinator heartbeat to the *command* claim path
(worker#196). The events claim path (`:9104`) and WAL fan-out (`:9108`) have no
equivalent.

**Confirmed, zero loss.** Restarting one pool drained it instantly (committed
3137 → 3231, lag 24 → 0); the control pool stayed frozen at `36/35`. All four
previously-stuck executions completed with **31 durable events each** — the
records were durable throughout. Consumer-side park, not writer-side loss.

**It is a race, not deterministic** — a later writer restart reattached cleanly
(6 = 6 both pools).

## 2. NEW DEFECT — the graceful seal does not reach the events log under load (noetl/ai-meta#226)

A mid-burst SIGTERM (backlog `shard_lag 61`, `subject_lag 24`) sealed **only the
first host**:

```
04:28:31.607917  sealing EHDB writer hosts before exit   hosts=2
04:28:31.608335  command-bus ingest face stopped — listener closed
04:28:31.867175  command-bus cursor persisted on shutdown
04:28:31.930239  command-bus log sealed on shutdown
<end of stream — pod gone>
```

No events-feed lines. No `Worker stopped`. Next boot:

```
group resumed  stored_cursor=3493  tip=3103  from_cursor=3103  clamped=true
```

**The reopened events log came back 390 records below the persisted cursor.**
The command-bus host sealed in 323 ms against a 15 s budget with 90 s of grace
remaining, so this is not budget exhaustion. Idle, the same code sealed both
hosts in 568 ms (P1). This is the #209 exposure realised on the **graceful**
path — what v5.92.0 shipped to fix.

## 3. Burst results (30 executions, concurrency 30 vs an 8-slot pool)

| Measure | Result | |
| :-- | :-- | :-- |
| Submission | 30 in **1.06 s** | |
| Outcome | **19 COMPLETED, 2 FAILED, 9 stuck RUNNING** | ❌ |
| Durable events | 876 vs 930 expected | ❌ |
| Duplicate event ids | **0** | ✅ |
| `ehdb_l0_out_of_order_appends` | **0** | ✅ |
| `ehdb_events_cursor_errors` | **0** across 631 s | ✅ |
| Dispatch latency | p50 **6511 ms**, p95 18072, p99 18388, min 230, max 20094 (n=94) | ⚠ **saturated — measures the pool, not the bus** |
| Sustained append rate | 945 command records / 631 s ≈ 1.5 rec/s (window includes idle) | ⚠ |
| **Exposure `min(1024, lag)` at peak** | commands **234**, events **292** | ✅ first real prod number |

The latency figures are a **burst/pool measurement** and must not be compared
against the 138.5 ms unsaturated reference. `min = 230 ms` is the only
bus-adjacent datapoint. **The unsaturated regime was never run**, so there is
still no valid prod bus-latency number.

The run is additionally invalidated as a clean measurement because the writer
was restarted mid-flight and that restart lost the events tail.

For comparison, #208's prod gate for a writer restart under load was
**38/38 COMPLETED, 0 dup / 0 loss, ~2.7 s redial**. This run was 19/30 with 2
hard failures.

## Gate

**P2 still has no clean pass, and P4 is NOT clear** — now for a stronger reason
than before. P4b's handover deliberately drops the writer pod, and #226 shows
that with load in flight that drop does not seal the events log.
