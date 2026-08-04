# P5 — post-converge re-validation, and the #227 root cause

**Run 2026-08-04 08:18–08:40 UTC against `shastaratech-noetl-prod`, on the
freshly-converged StatefulSet topology, worker v5.92.1.**

Two results: the IaC topology is **healthy and behaves identically to the
Deployment it replaced**, and noetl/ai-meta#227 is **root-caused** — with a
negative finding that rules out the obvious remedy.

---

# 1. Post-P4 re-validation — no regression from the handover

30-execution burst against the StatefulSet, with one graceful writer restart
mid-burst (backlog in flight: `state_materializer` lag 52).

## The restart, on the StatefulSet pod mounting the real PVCs

```
08:18:50.007249  sealing EHDB writer hosts before exit          hosts=2
08:18:50.007836  EHDB command-bus ingest face stopped — listener closed
08:18:50.007843  EHDB events ingest face stopped — listener closed
08:18:50.262840  EHDB command-bus cursor persisted on shutdown
08:18:50.263177  EHDB events-feed cursor persisted on shutdown
08:18:50.292514  EHDB command-bus log sealed on shutdown
08:18:50.314582  EHDB events-feed log sealed on shutdown
08:18:50.314857  EHDB writer hosts all sealed — shutdown complete  hosts=2
08:18:50.315723  Worker stopped
```

**308 ms for both hosts** (316 ms on the Deployment — identical behaviour).

Resume:

```
all three groups   stored=4675  tip=4675  from=4675  clamped=false  replay_records=0
command bus        from_cursor=53038  origin="persisted"
```

## Gates

| Gate | Result | |
| :-- | :-- | :-- |
| Both hosts seal under load | `hosts=2`, 308 ms | ✅ |
| `clamped=false`, exact cursor continuity | all three groups at 4675, zero replay | ✅ |
| Same PVCs still mounted after the restart | the three original claims | ✅ |
| **Writer Service endpoints after a pod restart** | re-resolved to the new pod IP `10.119.1.122` | ✅ |
| Consumers reattach | `6 == 6` on both pools | ✅ |
| Backlog drains | `grp_lag 0/0/0`, `cmd_lag 0` within 40 s | ✅ |
| Executions | **22 COMPLETED, 0 FAILED**, 8 stalled (#227) | ⚠ |
| Duplicate event ids / gaps | 0 | ✅ |
| `ehdb_l0_out_of_order_appends` | **0** | ✅ |
| `ehdb_events_cursor_errors` | **0** across 899 s | ✅ |
| Exposure `min(1024, lag)` peak | commands **223**, events **293** | ✅ |
| Synthetic execution (post-converge, single) | COMPLETED, `+31` cursor / 31 durable events | ✅ |
| SSE | gateway attached to `:9105`, 0 errors | ✅ |

The Service-endpoint result is the one worth calling out: the StatefulSet's
`statefulset.kubernetes.io/pod-name` selector **survives a pod restart** — the
replacement pod takes the same name and the Service re-resolves. The 8th-defect
fix is durable, not a one-time patch.

**KV remains structurally verified but not exercised** — the face is listening
and the gateway carries `NOETL_KV_ADDR`, but with no organic sessions the
gateway's KV client never dials (it is lazy), and the face must not be probed
directly (ehdb#311). Unchanged from P2; it needs real logins.

**Verdict: no regression from the P4 handover.** Exposure, latency-shape,
seal behaviour and consumer reattach all match the pre-converge Deployment.

---

# 2. noetl/ai-meta#227 — root cause

## The defect, in one line

**The off-server state builder's rehydrate-on-miss path never succeeds** — it
returns `empty` 100% of the time — so once an execution's chain is missing from
the pool-side WAL index, it can never be reconstructed, and the execution
retries forever.

## The evidence chain

The worker says it plainly, thousands of times:

```
off-server drive (stateless): WAL chain incomplete; returning no-op,
server reconcile will re-drive execution_id=…
```

Counters on the system pools after ~50 minutes:

```
state_builder_builds_total{outcome="incomplete"}          3724 / 6557
state_builder_builds_total{outcome="cold_rebuild"}          45 / 44
state_builder_drive_builds_total{outcome="served"}         192 / 182
state_builder_drive_builds_total{outcome="fallback_incomplete"} 462 / 455
state_builder_drive_builds_total{outcome="stateless_retry"}     462 / 455
state_builder_drive_wait_total{outcome="timeout"}         2163 / 2091
state_builder_evictions_total{reason="ttl"}                131 / 131
state_builder_rehydrate_total{outcome="empty"}             491 / 486
state_builder_event_scans_total                              0 / 0
```

`fallback_incomplete` **exactly equals** `stateless_retry` — every incomplete
build becomes a retry, and the loop never converges.

The decisive line is the rehydrate metric's own HELP text:

> `Cold-rebuild-on-miss outcomes — served / incomplete / empty / throttled`

Four outcomes are defined. **Only `empty` is ever observed — 491/486, and 72 on
a freshly-restarted pod within minutes. `served` never appears once.**

And `event_scans_total` is **0 by design** (RFC #115 tenet 3, "never scan
`noetl.event`"). So when the WAL index cannot serve a chain, there is **no
fallback path at all**: `chain_walk` is the only reader, rehydrate is its only
recovery, and rehydrate is broken.

## How an execution gets there

1. A writer restart interrupts an execution with a command in flight.
2. The pool-side WAL index has a gap for that execution — the chain link
   straddles the bounce.
3. `chain_walk` cannot reach genesis → `builds{incomplete}` →
   `resolve_offserver_orchestrate_input` returns `Noop` → the drive emits
   `__offserver_retry__`.
4. The server clears its in-flight guard and the reconcile poller re-drives.
   Each attempt re-walks and is still incomplete.
5. After `NOETL_STATE_INDEX_TTL_SECS=900` the index entry is TTL-evicted
   (`evictions{reason="ttl"} 131`).
6. `NOETL_STATE_INDEX_REHYDRATE_ON_MISS=true` fires — and returns **empty**.
   The chain is now unrecoverable.
7. The execution retries forever, which is the sustained ~2 rec/s on an
   otherwise idle cluster.

## The three observed stall shapes, all the same cause

**(a) Step executed twice, then stall** — `342886409549389824`:

```
04:28:18  step.enter      fetch_data
04:28:18  command.issued  fetch_data     <- issued pre-restart
          [writer restart 04:28:29–04:28:47]
04:30:03  step.enter      fetch_data     <- re-entered
04:30:03  command.issued  fetch_data     <- DUPLICATE
04:30:04  command.claimed / started / call.done / command.completed
04:30:17  command.claimed / started / call.done / command.completed   <- the FIRST command, redelivered
          … and nothing further.
```

The guardrail re-issued while the bus was also going to redeliver the original.
Both copies ran. This is a **secondary** defect — the re-issue is not idempotent
per `(execution, step)` — but the stall itself is still the incomplete-chain
loop.

**(b) Limping one step per re-drive** — `342926815876096000` advanced its next
step **16 minutes** after the restart, then stalled again. A re-drive that
happened to find a walkable chain.

**(c) Terminal step done, no terminal event** — `342926815586689024` ran all the
way through `end` (`command.completed success node=end` at 07:10:33) and never
emitted `playbook.completed`. Emitting the terminal event needs one more state
build, and that build is incomplete too. Functionally finished, permanently
`RUNNING`.

## Not a P4 or bus regression

Stall rates across three identical bursts, each with a mid-burst writer restart:

| Image / topology | Result |
| :-- | :-- |
| v5.92.0, Deployment | 19 COMPLETED / **2 FAILED** / 9 stalled |
| v5.92.1, Deployment | 23 COMPLETED / 0 FAILED / 7 stalled |
| v5.92.1, **StatefulSet (post-P4)** | 22 COMPLETED / 0 FAILED / 8 stalled |

Consistent ~25–30% stall rate when a restart lands mid-flight, unchanged by the
#225/#226 fix and unchanged by the P4 handover. It is orchestration-side, as
suspected.

## Proposed fix (NOT implemented)

In priority order:

1. **Fix rehydrate.** `rehydrate_total{outcome="empty"}` at 100% is the bug.
   It should reconstruct the chain for a missed execution — reading the durable
   events tier through the **server API** (per `data-access-boundary.md`, workers
   do not touch `noetl.*` directly), or by replaying the events feed from a
   cursor below the execution's genesis. Until it can return `served`, TTL
   eviction is a one-way door for any execution older than 15 minutes.
2. **Bound the retry.** `stateless_retry` must not loop unbounded. After N
   attempts the execution should take the **`playbook.failed`** path (see below)
   with a reason, rather than sitting invisibly in `RUNNING`.
3. **Do not TTL-evict non-terminal executions that are actively being
   re-driven.** Reset the TTL on each drive attempt, or exempt non-terminal
   executions from the sweep.
4. **Make the guardrail re-issue idempotent** per `(execution_id, step,
   attempt)`, so a redelivered original and a re-issued duplicate cannot both
   run the step. Separate defect; worth its own issue if #227 is scoped to the
   stall.

Detection, independent of the fix: `builds{outcome="incomplete"}` climbing while
`drive_builds{outcome="served"}` is flat is the exact alert condition, and
neither is scraped by GMP today (only the writer's `:9102` and `:9090` are).

## Can the 24 stalled executions be resolved without fabricating events?

**Tested, and the obvious remedy does not work.** Restarting both system pools —
which forces a cold rebuild of the WAL index, and which is what cleared #225 —
recovered **zero** executions:

```
before:  22 RUNNING, 2 FAILED
after :  24 RUNNING, 4 FAILED      (movers: none from the restart)
fresh pods within 8 min:  builds{incomplete} 245/246,  rehydrate{empty} 61/61
```

The chain is not reconstructible from any source the worker is willing to read,
so a cold start does not help.

**But a legitimate terminal path does exist, and the platform already uses it.**
Two of the stalled executions terminated on their own with a real event emitted
by the orchestrator:

```
342944395210792961:  08:22:11  playbook.failed  FAILED  playbook
342944395214987264:  08:22:11  playbook.failed  FAILED  playbook
```

So `playbook.failed` is a transition the platform emits itself. **The clean
resolution is to make that path fire for the rest** — i.e. proposal 2 above, a
bounded retry that ends in `playbook.failed`. That is the orchestrator emitting
its own terminal event from its own state machine, not a fabricated record.

**Recommendation:** do **not** hand-write terminal events into the append-only
log. Land proposal 2 (bounded retry → `playbook.failed`) and the 24 stalled
executions will drain themselves legitimately on the next reconcile pass. If
they must be cleared sooner, the only other honest option is to leave them
`RUNNING` and filter them out of dashboards until the fix ships — they are inert
apart from the ~2 rec/s re-drive traffic.

---

## Prod state at the end of this run

All pods Running, StatefulSet writer 1/1 on the original PVCs, every lag 0,
`cursor_errors` 0, `out_of_order_appends` 0, KEDA + HPA intact. 24 executions
stalled per #227, generating the known re-drive traffic. Sampler cleaned up.
