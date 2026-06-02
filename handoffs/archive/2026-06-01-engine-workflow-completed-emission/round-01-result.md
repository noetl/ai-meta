---
slug: 2026-06-01-engine-workflow-completed-emission
round: 01
status: complete
pr: https://github.com/noetl/noetl/pull/649
tracks: noetl/ai-meta#37
---

## PR

https://github.com/noetl/noetl/pull/649

## Diagnosis

**Root cause** (single race condition, two symptoms):

The Rust worker posts `call.done` before `command.completed`. When `call.done` for the terminal `done` step arrives, the engine invokes `_count_durable_pending_commands` which queries `noetl.command WHERE status NOT IN ('COMPLETED','FAILED','CANCELLED')`. The `done` command is still RUNNING because `command.completed` has not yet been processed. This produces `durable_pending_count = 1` → `has_pending_commands = True` → the completion gate at `events.py:2532` never fires → `workflow.completed` is never emitted.

The status endpoint's `node_name == "end"` literal (lines 258 and 297 in `execution.py`) was a separate but related hardcoding that would fail for any terminal step not named `"end"`.

**Why it worked for the Python worker**: the Python worker emits `call.done` + `command.completed` in a single batch request, so both are persisted atomically before the engine runs. The durable count sees the completed command.

**Why `is_terminal_step` was correctly True**: `done` step has no `next` block, so `step_def.next` is falsy and `is_terminal_step = True`. The gate was correct; the blocker was `has_pending_commands`.

## Fix shapes

**Fix A** (`noetl/core/dsl/engine/executor/events.py`):
- `_count_durable_pending_commands` gains `exclude_command_id: Optional[str]` parameter (`events.py:33-84`).
- Call site at `events.py:2447-2466`: extracts `command_id` from `call.done`/`call.error` payload, passes it as `exclude_command_id` to skip the still-RUNNING triggering command.
- DEBUG log at `events.py:2546-2551` when `is_terminal_step` fires.

**Fix B** (`noetl/server/api/core/execution.py`):
- State-store path (`:307-317`): replaces `state.current_step == "end"` with `state.get_step(current_step).next is None`.
- Event-log fallback path (`:263-266`): replaces `node_name == "end"` with `pending_count == 0` check.
- Both paths now query `PENDING_COMMAND_COUNT_SQL` for `command.completed`/`call.done`/`step.exit` events.

## Test coverage

- `tests/unit/dsl/engine/test_terminal_step_completion.py`: 2 tests — engine emits `workflow.completed`+`playbook.completed` for 3-step playbook with terminal step `done`; DEBUG log fires with `execution_id` + step.
- `tests/unit/server/api/test_status_terminal_step_inference.py`: 6 tests — inference logic for terminal `done`, non-terminal `step_a`, failed state, missing from `completed_steps`.

## Blockers

None. The parallel #36 agent touches `batch.py` and `arrow_ipc.py`; no file overlap.
