# Deep-Dive Addendum: Prioritized Hypotheses and Code Pointers

## Context
This addendum complements:
- sync/issues/2026-04-16-bug-pft-distributed-runtime-stall-606790043104968712.md

Execution under investigation:
- execution_id: 606790043104968712

## Prioritized Hypotheses

### P0: Loop epoch reset reuses/overlaps epoch identity and loses progress accounting
Confidence: High

Why this is likely:
- Server log sequence shows loop completion and immediate restart path.
- Right after restart, the engine logs stale-state reset:
  - "Reset stale distributed state for new invocation of fetch_assessments (completed=100 scheduled=100 size=100 ...)"
- Non-checkpointer events stop shortly after this point while execution remains RUNNING.

Code pointers:
- repos/noetl/noetl/core/dsl/engine/executor/commands.py:398
  - reset path around stale distributed state and state reinit
- repos/noetl/noetl/core/dsl/engine/executor/commands.py:360
  - surrounding loop completion/restart conditions

Owner suggestion:
- Engine/orchestrator owner (DSL executor + transitions)

Targeted checks:
1. Verify whether reset path creates a truly new loop epoch id and whether all downstream producers/consumers use the new epoch consistently.
2. Confirm that completed/scheduled counters after reset are initialized to values that permit forward scheduling.
3. Emit explicit diagnostic event after reset containing new epoch id, scheduled_count, completed_count, and first N planned iteration ids.

---

### P1: NATS K/V loop iteration key enumeration intermittently empty causes scheduler blind spots
Confidence: Medium-High

Why this is likely:
- Repeated warning in server logs during the loop boundary:
  - "Failed to enumerate loop iteration state keys in NATS K/V ... nats: no keys found"
- If enumeration is used for bookkeeping/resume/termination decisions, missing keys can misclassify loop state.

Code pointers:
- repos/noetl/noetl/core/cache/nats_kv.py:710
  - _list_loop_iteration_payloads warning path
- repos/noetl/noetl/core/cache/nats_kv.py:680
  - key prefix generation and iteration key scan context

Owner suggestion:
- Cache/NATS integration owner

Targeted checks:
1. Distinguish between "no keys yet" vs "unexpectedly no keys after scheduling" and treat them differently.
2. Add counter metrics for enumeration attempts and empty results partitioned by step/event_id.
3. On empty enumeration in a post-scheduling context, emit a hard diagnostic event with execution_id, step, event_id, and expected cardinality.

---

### P2: Silent DB service error on status path obscures root progression state
Confidence: Medium

Why this is likely:
- Server logs include repeated error lines from database service while status endpoint still returns 200.
- Errors may not be fatal but can hide useful internal state and create observability gaps.

Code pointers:
- repos/noetl/noetl/server/api/database/service.py:179
  - error handling around database operation/commit path
- repos/noetl/noetl/server/api/database/service.py:150
  - surrounding execute/commit flow and exception handling

Owner suggestion:
- Server API/database service owner

Targeted checks:
1. Capture full exception content and operation metadata (query/procedure type, credential alias, transaction boundary).
2. Ensure status-related DB reads are isolated from unrelated write/commit failures.
3. Add structured error code/classification to status responses when internal DB faults occur.

---

### P3: Transport is healthy; logical scheduler dead-zone likely after loop restart
Confidence: Medium

Why this matters:
- NATS stream/consumer state at capture time shows no backlog and no ack pressure.
- Worker pods are alive and heartbeating.
- This combination indicates a logical orchestration dead-zone rather than transport starvation.

Evidence pointers:
- sync/issues/2026-04-16-pft-distributed-stall-606790043104968712/nats_stream_info_NOETL_COMMANDS.txt
- sync/issues/2026-04-16-pft-distributed-stall-606790043104968712/nats_consumer_info_noetl_worker_pool.txt
- sync/issues/2026-04-16-pft-distributed-stall-606790043104968712/k8s_pods_noetl.txt

Owner suggestion:
- Runtime orchestration owner, with NATS owner in support

## What to instrument next (minimal and high-signal)
1. Post-reset scheduling audit event:
   - fields: execution_id, step, old_epoch_id, new_epoch_id, collection_size, scheduled_count, completed_count, first_5_iteration_ids
2. Loop liveness heartbeat (per step):
   - fields: execution_id, step, last_non_checkpointer_event_at, seconds_since_progress, pending_iteration_count
3. Guardrail event:
   - emit runtime.stall.suspected when only checkpointer events are seen for >60s while execution.status=RUNNING
4. K/V consistency probe event:
   - when enumeration is empty after scheduled_count>0, include prefix, event_id, and expected_count

## Suggested ownership split for triage
- Engine/orchestrator:
  - commands.py reset/restart semantics, loop epoch identity, progression invariants
- NATS/cache:
  - key enumeration guarantees and fallback behavior
- Server DB API:
  - visibility into status-path DB errors and structured diagnostics

## Exit criteria for fix validation
1. Re-run same distributed playbook and confirm:
   - non-checkpointer events continue beyond previous boundary
   - execution reaches terminal COMPLETED or FAILED
2. Confirm no repeated empty K/V enumeration warnings at active loop boundaries.
3. Confirm no silent DB service errors on status polling path.
4. Capture and archive the same artifact bundle format for before/after comparison.
