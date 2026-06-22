---
thread: 2026-06-18-orchestrate-plugin-dissolution
round: 2
from: claude
to: claude
created: 2026-06-18T19:35:00Z
in_reply_to: round-02-prompt.md
tracks: noetl/ai-meta#111
status: complete
---

# Round 2 complete — server-API-only assessment + committed off-server e2e rig, live-green

Picked up the broader step-2 wrap-up. Produced the status assessment, shipped a
committed e2e topology rig (merged + pointer-bumped), opened #111 as the durable
home for the residual gap, and surfaced two production-policy decisions rather
than acting on them. `status: complete`.

## Status assessment — server-API-only

**Step 2 (orchestrator → `system/orchestrate` plug-in) is COMPLETE.** The
evaluate loop runs off-server on the system pool by default (server v3.28.0,
#108 (c)); the in-server shadow + `wasmtime` server dep are gone (#110,
`f3043c9`).

What STILL lives in the server (verified against `f3043c9`):

| Server responsibility | Where | API-only? | Moves under |
| :-- | :-- | :-- | :-- |
| Schedule the drive (load events → rebuild `WorkflowState` → resolve cursor claim refs → dispatch ONE `system/orchestrate` command) | `events.rs::trigger_orchestrator_inner` ~L1838-2119 | Kernel scheduler — stays | — |
| Apply the worker-computed result (decode `OrchestrationResult` → emit events + issue commands + terminal event) — **server is sole writer to `noetl.event`/`noetl.command`** | `events.rs::apply_worker_orchestration` ~L2341 → `apply_orchestration_result` ~L2213 | **No** — server writes the log | **#103 CQRS** (materializer becomes sole writer) |
| Rebuild `WorkflowState` from events to bound the drive input | `events.rs` + `orchestrate-core/state.rs` `from_events` | **No** — read-then-compute | **#104 NATS-WAL** / #107 step 4 (Postgres demotion) |
| In-process drive fallback (`evaluate_state` via `WorkflowOrchestrator`) | `events.rs` ~L2122 | dead on default path; compiled in | operator decision A (below) |
| Event ingest, command claim/get, catalog CRUD, all read APIs | `handlers/*` | the API-only core | — |

**Done / in-progress / remaining**

- **Done:** orchestrator evaluate extracted to wasm + run off-server on the
  system pool, default-on, zero `noetl.event` burst, shadow retired. Now with
  committed e2e coverage (this round).
- **In progress (other umbrellas):** server-as-sole-writer removal → #103;
  from-events rebuild removal → #104.
- **Remaining (this thread):** only operator decisions A + B (below). No safe
  non-policy refactor is left in the orchestrator-dissolution thread.

## What I shipped

- **e2e rig** `repos/e2e/scripts/kind_validate_orchestrate_offserver.sh` —
  [e2e#59](https://github.com/noetl/e2e/pull/59), squash-merged → e2e
  `977efc2`; ai-meta `repos/e2e` pointer `94aa7f1` → `977efc2`. Hard-asserts:
  COMPLETED; **0** `__orchestrate__` rows in `noetl.event`; `__orchestrate__`
  rows present in `noetl.command`; `noetl_orchestrate_drive_total` dispatched +
  applied advance, no `decode_error`; `noetl_orchestrate_shadow_total` absent.
  Doc: `repos/e2e/docs/operations/local-kind.md`.
- **#111** opened (ai-task, repo:e2e; board → In progress) — durable home for
  the e2e coverage + the gap assessment + decisions A/B. #107 commented with
  the step-2 status; #107 board untouched (stays Todo as the strategic roof).

## Live validation (kind-noetl, server v3.28.0 / post-#110 `oc-noshadow`)

Rolled `oc-noshadow` (the post-#110 image already built by round 1, content-
faithful to `f3043c9`) with `NOETL_ORCHESTRATE_PLUGIN_DRIVE=true`. Clean boot:
`system/orchestrate@1` seeded, no shadow loader line, `/metrics` shadow series
absent. Ran the rig:

```
final_status=COMPLETED
__orchestrate__ in noetl.event   = 0
__orchestrate__ in noetl.command = 4   (status PENDING, worker_id=null — see B)
drive metric: dispatched +4 / applied +4 / decode_error +0
noetl_orchestrate_shadow_total absent
=> PASS
```

`applied +4` is the off-server proof: that counter only increments in
`apply_worker_orchestration`, which runs only when a worker returns a decoded
`OrchestrationResult` via the `call.done` callback. The system pool is the sole
subscriber to `noetl.commands.system.>` (where the drives route) and declines
out-of-pool notifications, so the drives necessarily ran on the system pool.

**Kind restored** to its as-found baseline afterward: image `oc-pool`,
`NOETL_ORCHESTRATE_PLUGIN_DRIVE=false`, `NOETL_ORCHESTRATE_PLUGIN_SHADOW=false`.

## Surfaced for the operator (NOT done unilaterally)

- **(A) Retire the in-process drive fallback.** Gated on prod adopting a
  post-#108 image first. Prod GKE still runs `server-rust:batch-dispatch-v1`
  (pre-#108) — the worker-driven drive is not live in prod, so removing the
  `=false` revert now is premature. This is the same class of production-policy
  call as the #108 (c) default-flip.
- **(B) Reap `__orchestrate__` delivery rows.** Each drive writes one PENDING
  row to `noetl.command` (`worker_id=null`) that is never reconciled to terminal
  — its lifecycle events are suppressed from `noetl.event`, so the normal
  claim→COMPLETED status update never fires. Accumulates one row per drive
  (~694 in a single #108 soak). Wants a TTL / mark-terminal-on-apply / separate
  delivery-table strategy. Scale-relevant, not a correctness bug.

## Issues observed

- The rig's informational system-pool-isolation log grep returns 0 hits on both
  pools — the system-pool worker logs only at INFO and emits no per-claim line,
  so there's nothing to grep. The metric (`applied`) + the structural routing
  argument are the real proof; the log grep is informational only. Left as-is.

## Manual escalation needed

Decisions A + B are operator calls (tracked on #111). Nothing else blocking.
The thread's shipped work (#108 + #110) is closed; residual lives on #111.
