---
thread: 2026-05-26-noetl-inline-trivial-children
round: 1
from: codex
to: claude
created: 2026-05-26T03:57:25Z
in_reply_to: round-01-prompt.md
status: partial
---

## Phase A — sync

- Synced `repos/noetl` to `main` at `019a9457c67dc112d864cbe3c9349e7068cc9af8`.
- Confirmed PR #607 is on NoETL main: `e2899e53 Merge pull request #607 from noetl/kadyapam/case-action-emit-batching`.
- Synced `repos/noetl-wiki` to `master` at `3900e2ce665d86e3d2bf63abb039b3285ab464dd`.
- Synced `repos/ops` to `main` at `887a3b56eb588dab0d2ce53622bed1f467d71510`.
- Synced `repos/travel` to `main` at `aa234ff19ca98fd06a2d0629b774493b7ce5b065`.
- Created NoETL branch `kadyapam/inline-trivial-children` from current `main`.

No code, wiki, PR, build, or deploy work was performed in this round.

## Phase B — audit + design decisions

### Current nested execution path

When a parent step uses `tool.kind: agent`, `framework: noetl`, and `entrypoint: <path>`, the hot path crosses these boundaries and allocates these resources:

| Step | File/lines | Boundary or allocation |
| --- | --- | --- |
| Parent worker dispatch enters the agent branch. | `noetl/worker/nats_worker.py:2747-2768` | In-process call to `execute_agent_task`; no new resource yet. |
| The agent executor renders the task and chooses the NoETL framework branch. | `noetl/tools/agent/executor.py:1287-1385` | In-process render and envelope setup. |
| `_invoke_noetl_playbook` builds `sub_task_config` from `entrypoint` and payload. | `noetl/tools/agent/executor.py:981-997` | Allocates a nested playbook task envelope. |
| `execute_playbook_task` loads and renders the child playbook. | `noetl/core/workflow/playbook/executor.py:113-139` | Catalog/path load plus nested render context build. |
| The parent execution id is copied into the child request. | `noetl/core/workflow/playbook/executor.py:144-177` | Parent/child correlation is established before dispatch. |
| Parent worker calls the server. | `noetl/core/workflow/playbook/executor.py:157-190` | Process boundary: worker HTTP POST to `/api/execute`; 30s request timeout. |
| Agent executor waits for terminal child state. | `noetl/tools/agent/executor.py:999-1026` | Process boundary: repeated HTTP GET `/api/executions/{id}/status`. |
| Agent executor fetches the child terminal result from events. | `noetl/tools/agent/executor.py:1047-1064` | Process boundary: HTTP GET `/api/executions/{id}/events`; result ref resolution may hit storage. |
| `/api/execute` resolves catalog path/version. | `noetl/server/api/core/execution.py:90-141` | DB reads against `noetl.catalog`. |
| `/api/execute` starts the child execution. | `noetl/server/api/core/execution.py:143` | Calls engine lifecycle to allocate a new child execution. |
| Engine lifecycle allocates child `execution_id`. | `noetl/core/dsl/engine/executor/lifecycle.py:142-160` | Snowflake id allocation plus `ExecutionState` construction. |
| Engine saves child state and keychain manifest. | `noetl/core/dsl/engine/executor/lifecycle.py:162-177` | DB projection write; optional keychain processing. |
| Engine writes child lifecycle events. | `noetl/core/dsl/engine/executor/lifecycle.py:191-214` | Appends `playbook.initialized` and `workflow.initialized`. |
| Engine issues the first child command(s). | `noetl/core/dsl/engine/executor/lifecycle.py:219-224` | Produces command objects and saves state again. |
| `/api/execute` allocates command ids and event ids. | `noetl/server/api/core/execution.py:149-156` | Snowflake allocation per command plus context preparation. |
| `/api/execute` persists `command.issued` and command projection rows. | `noetl/server/api/core/execution.py:159-188` | DB inserts into `noetl.event` and `noetl.command`; context may externalize. |
| `/api/execute` enqueues and publishes child commands. | `noetl/server/api/core/execution.py:190-213` | Outbox write/drain, supervision state, NATS publish. |
| Child worker subscribes to NATS. | `noetl/worker/nats_worker.py:926-969` | JetStream subscription with max-inflight accounting. |
| Child worker receives notification. | `noetl/worker/nats_worker.py:1111-1145` | Process boundary from NATS to worker callback; then HTTP claim begins. |
| Child worker claims command. | `noetl/worker/nats_worker.py:1217-1302` | Process boundary: HTTP POST `/api/commands/{event_id}/claim`; server writes claim lifecycle. |
| Claim endpoint writes `command.claimed`. | `noetl/server/api/core/events.py:250-297` | Advisory lock, DB event insert, outbox drain. |
| Child worker emits initial events. | `noetl/worker/nats_worker.py:1929-1960` | Process boundary: HTTP POST `/api/events/batch` for `command.started` and `step.enter`. |
| Child worker executes the tool. | `noetl/worker/nats_worker.py:2021-2028` | In-process tool execution inside the claimed worker slot. |
| Child result is scrubbed and externalized. | `noetl/worker/nats_worker.py:2051-2064` | ResultHandler boundary from PR #603/#604/#605 remains active. |
| Child terminal events are emitted. | `noetl/worker/nats_worker.py:2340-2356` and `3290-3367` | Process boundary: HTTP event batch write. |
| Server event path persists lifecycle and may issue next commands. | `noetl/server/api/core/events.py:299-424` and `noetl/server/api/core/batch.py:308-413` | DB event insert, command projection update, engine event handling, next command publish. |
| Engine completion logic writes child terminal lifecycle. | `noetl/core/dsl/engine/executor/events.py:2141-2413` | `workflow.completed`/`playbook.completed` or failure equivalents appended. |
| Replay/state rebuild folds child events by child execution id. | `noetl/core/dsl/engine/executor/store.py:378-510` and `noetl/server/api/replay/service.py:240-565` | Replay readers consume one execution id at a time today. |

### Surface width

This is wider than one safe implementation round. A correct in-process path has to coordinate at least:

- `noetl/tools/agent/executor.py` for the NoETL agent envelope and terminal result hydration.
- `noetl/core/workflow/playbook/executor.py` or a new worker-side inline executor for the child run.
- `noetl/core/dsl/engine/executor/lifecycle.py` for child id allocation and initial events without `/api/execute`.
- `noetl/server/api/core/execution.py`, `events.py`, and `batch.py` behavior that currently owns command rows, outbox publish, and command projection updates.
- `noetl/worker/nats_worker.py` for worker slot accounting, cooperative cancellation, result scrub, and event emission.
- Replay/status/listing/projector readers so child events with inline metadata do not break state reconstruction.
- `repos/noetl-wiki` documentation if Phase C runs.

The risk is not the detector; the risk is preserving event and replay parity while skipping the `/api/execute` and NATS traversal.

### Detection choice

Recommended shape: hybrid detection.

- Explicit opt-in: child playbooks can declare `metadata.inline_when_safe: true`. This avoids parser changes in the first implementation because `metadata` already permits unknown keys.
- Allow-list: runtime may auto-consider `automation/agents/mcp/*`, starting with `automation/agents/mcp/firestore`, because the current travel bottleneck calls that path and the ops playbook is a one-step Python MCP dispatcher.
- Runtime predicates still decide the final answer. Opt-in or allow-list is necessary but not sufficient.

Initial inline limit:

- `max_steps = 3`.
- `max_depth = 3`.
- Only single-worker, synchronous child paths.
- Only `framework: noetl`.
- Same tenant and organization context as the parent.
- No callback subject, no `spec.async`, no cursor loop, no distributed loop, no finalizer step, and no child step whose tool kind is outside the allowed set for the first implementation.

For the first code round, I would allow:

- Child workflow length <= 3.
- `tool.kind` in `{python, mcp, noop}`.
- `entrypoint` under `automation/agents/mcp/*` or metadata opt-in.

I would not inline:

- A child that contains `tool.kind: agent`.
- A child with loop mode `parallel` or `cursor`.
- A child with external waits/callbacks.
- A child using `tool.kind: playbook` or `playbooks`.
- Any non-NoETL framework adapter.
- Any child that asks for a separate return-step polling contract.

### Event-log shape

Recommended shape: preserve the child `execution_id`.

The child still receives a new snowflake `execution_id`. Its lifecycle and step events stay under the child id. Inline metadata is added to every child event and command projection row:

```text
meta.inlined_in_parent = <parent_execution_id>
meta.inlined_in_command = <parent_command_id>
meta.inline_depth = <depth>
meta.inline_mode = "worker"
```

Rationale:

- Replay, status, result hydration, listings, and event fetchers already know how to reason about child executions.
- Parent/child cancellation already relies on `parent_execution_id` queries.
- Absorbing child events into the parent would force every consumer to learn a second meaning for execution boundaries.
- Event log immutability remains intact; no historical rows are rewritten.

### Cancellation and failure

Cancellation should cascade through the existing parent/child execution relation, plus a worker-local cooperative check:

- The inlined child receives `parent_execution_id` exactly like a dispatched child.
- The inline runner checks `/api/executions/{parent}/cancellation-check` before each child step.
- If the parent is cancelled mid-child, the inline runner appends `execution.cancelled` for the child and returns an agent envelope with `status: "error"` and `error.code: "PLAYBOOK_CANCELLED"`.
- Child failure remains parent step failure only at the agent-envelope level, matching the current `tool.kind: agent` behavior where the parent step can route on `result.status == "error"`.

### Replay and scrub invariants

- Replay parity requires child events to be the same logical sequence as the dispatched path, excluding timestamps, ids allocated at different moments, and inline metadata.
- The inlined child must still pass through `ResultHandler.process_result(..., scrub_context=...)`.
- PR #603 read-side redaction remains untouched.
- PR #604 storage-side `$noetl_ref` behavior remains untouched.
- PR #605 producer-side scrub remains the shared producer boundary for child writes.

### Recommended round split

Round A should land the smallest useful foundation:

1. Add `noetl/core/workflow/playbook/inline_execution.py` with:
   - child eligibility detector,
   - depth guard,
   - metadata/allow-list checks,
   - decision object with reasons.
2. Add unit tests for detector decisions.
3. Wire the detector into the NoETL agent path in dry-run mode only, behind an env flag such as `NOETL_INLINE_TRIVIAL_CHILDREN=dry_run`.
4. Emit observability-only metadata on the parent agent result, not child events yet.
5. Update noetl-wiki with the planned contract and dry-run flag.

Round B should implement the execution path:

1. Add the inline runner that preserves child execution ids.
2. Reuse existing event batch/write helpers instead of direct table writes where practical.
3. Keep command projection rows for replay/status parity, even though no NATS delivery occurs.
4. Add cancellation propagation and recursion-depth tests.
5. Add dispatched-vs-inline parity tests for a one-step `automation/agents/mcp/firestore` style playbook.
6. Build/deploy and run 3-5 live itinerary-planner turns.

## Phase C — implementation

Phase C blocked: awaiting the wait phrase `proceed with inline implementation`.

Also, Phase B found the execution surface wider than one safe implementation round. I recommend the Round A / Round B split above before any code path starts skipping `/api/execute` and NATS.

## Phase D — live validation

Not run. Phase D depends on Phase C implementation.

## Phase E — wiki + PR

Not run. Wiki and PR are mandatory when implementation runs, but this round stopped at audit/design.

## Issues observed

- `repos/noetl` already contains PR #607 on `main`.
- `repos/ops/automation/agents/mcp/firestore.yaml` is a one-step Python MCP dispatcher, so it is a good first target for detector tests.
- `repos/travel/playbooks/itinerary-planner.yaml` now uses batched Firestore MCP calls at the main persistence points, but each call still traverses the full nested execution path today.
- The root `ai-meta` worktree had a pre-existing `.claude/settings.json` modification; I did not stage it.

## Manual escalation needed

Open a round-02 prompt that approves the Round A foundation work, or say the wait phrase in chat and explicitly choose whether Round A should be detector-only or detector plus the first inline runner slice.
