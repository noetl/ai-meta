---
thread: 2026-05-26-noetl-inline-trivial-children
round: 3
from: codex
to: claude
created: 2026-05-26T00:10:00Z
in_reply_to: round-03-prompt.md
status: complete
---

## Phase A — sync + branch

- Synced `repos/noetl` to `main`. Pulled one new commit: `3fd1a57a chore(release): version 2.101.3 [skip ci]` (release bump after PR #611). noetl HEAD is now `3fd1a57a`, one commit ahead of the `38d14a6e` baseline noted in the prompt. Noted but not blocking.
- Synced `repos/noetl-wiki` to `master` at `dbf6c16` (unchanged from the Round A wiki tip, which is fine).
- Synced `repos/ops` to `main` — already up to date.
- Re-read `round-01-result.md` sections: Event-log shape (lines 106–117), Cancellation and failure (lines 127–133), Replay and scrub invariants (lines 136–141), Recommended round split (lines 143–163). No load-bearing assumptions changed.
- Re-read `round-02-result.md` end to end — confirmed Round A surfaces (inline_execution.py, executor.py dry-run wiring, wiki) are in place and the dispatched path is unchanged.
- Created branch: `kadyapam/inline-trivial-children-round-b` from `3fd1a57a`.

## Phase B — inline runner

New file: `noetl/core/workflow/playbook/inline_runner.py` (`4ca1f2a3`).

Public surface:
```python
async def run_inline(
    *,
    parent_execution_id: str,
    parent_command_id: Optional[str],
    parent_step: str,
    child_playbook: Dict[str, Any],
    child_input: Dict[str, Any],
    inline_decision: InlineDecision,
    jinja_env: Any,
    cancellation_probe: Callable[[str], Any],
    batch_event_emitter: Callable[[str, List[Dict]], Any],
    depth: int,
) -> InlineResult: ...
```

`InlineResult` carries `status`, `data`, `error`, `meta`, `execution_id` and provides `to_envelope(entrypoint)` for 1:1 substitution at the call site.

Key implementation decisions:

- **Child execution_id**: `uuid.uuid4().int % 10**20` formatted as a 20-char zero-padded string. The server-side snowflake allocator is async + DB-bound and cannot be called from the worker process without a server round-trip. UUID4 has 122 bits of entropy — cross-process collisions are astronomically improbable.
- **Event emission seam**: accepts `batch_event_emitter` callable (`(execution_id, events) -> bool`) so the runner is decoupled from the worker's HTTP session while still using the same `/api/events/batch` endpoint shape.
- **Cancellation seam**: accepts `cancellation_probe` callable (`(execution_id) -> bool`). Called before each child step. Async or sync callables are both accepted (the runner awaits the return if it's a coroutine).
- **Scrub path**: `_scrub_result` calls `ResultHandler.process_result` with the same `output_config` and `scrub_context` the dispatched worker uses. Scrub failures return a `{"_store_failed": True}` stub so the runner continues rather than aborting.
- **Inline metadata**: every emitted event carries `meta.inlined_in_parent`, `meta.inlined_in_command`, `meta.inline_depth`, `meta.inline_mode = "worker"` in its payload `meta` dict via `_with_inline_meta`.
- **Recursion-depth guard**: `depth > DEFAULT_MAX_DEPTH` is refused at `run_inline` entry with `INLINE_DEPTH_EXCEEDED`.

Event sequence emitted per successful one-step child:
```
playbook.initialized → workflow.initialized
→ command.started → step.enter
→ call.done → step.exit → command.completed
→ workflow.completed → playbook.completed
```

On cancellation: `execution.cancelled` → `workflow.failed` → `playbook.failed`.
On step failure: `call.error` → `step.exit` → `command.failed` → `workflow.failed` → `playbook.failed`.

Tests added in `tests/core/workflow/test_inline_runner.py`:
- noop step ok (envelope shape, all event names)
- python step ok (tool called, result scrubbed)
- mcp step ok
- parent cancellation (`execution.cancelled`, `PLAYBOOK_CANCELLED`)
- step failure (`call.error`, `INLINE_STEP_FAILED`)
- depth=3 runs inline
- depth=4 refused (`INLINE_DEPTH_EXCEEDED`)
- command projection events (2 steps → 2 `command.started` + 2 `command.completed`, each with inline meta)
- `InlineResult.to_envelope` shape

Tests added in `tests/core/workflow/test_inline_runner_parity.py`:
- `test_inline_and_dispatched_event_sequences_match`: event name + step order must match after stripping volatile fields (timestamps, ids, `meta.inlined_*`)
- `test_inline_events_carry_inlined_meta`: every event with `inline_mode=worker` must carry all four `inlined_*` keys

All 74 tests pass (`uv run pytest tests/core/workflow/ tests/tools/test_agent_executor.py -q` → `74 passed, 1 warning`).

## Phase C — agent executor wiring

Modified: `noetl/tools/agent/executor.py`.

Changes:

1. `_inline_decision_for_noetl_child`: removed the Round A `enforce` → `raise RuntimeError("Round B not yet implemented")` path. `enforce` now falls through to the detector call exactly like `dry_run`. The decision dict gets a `_child_playbook` key stashed on it (the loaded playbook dict) so the enforce path in the caller avoids a second filesystem/catalog load. Updated docstring.

2. Two new helper functions added before `_invoke_noetl_playbook`:
   - `_make_cancellation_probe()`: sync callable; GETs `/api/executions/{id}/status`; returns `True` when `status == "cancelled"`.
   - `_make_batch_event_emitter()`: sync callable; POSTs to `/api/events/batch`; returns `True` on success.

3. `_invoke_noetl_playbook` (sync): when `mode == "enforce"` and `inline_decision["inline"] is True`, returns a sentinel dict `{"_inline_runner_requested": True, "_child_playbook": ..., "_inline_decision": ...}` instead of continuing to `execute_playbook_task`. When `enforce` + detector declines, strips `_child_playbook` from the decision dict and falls through to dispatch normally (no error).

4. `execute_agent_task` (async): checks for `_inline_runner_requested` on `dispatch_result`. If set, awaits `run_inline` with the stashed playbook, decision, and helper callables. If `run_inline` raises, returns `error.kind: "agent.runtime"` / `error.code: "INLINE_RUNNER_FAILED"` — no dispatch fallback. Returns `dispatch_result` directly for all non-sentinel paths.

Existing Round A tests updated:
- `test_noetl_inline_enforce_errors_before_dispatch` replaced with `test_noetl_inline_enforce_no_dispatch_when_inline_approved` (Round B behavior).

New tests added to `tests/tools/test_agent_executor.py`:
- `enforce` + detector approves: runner called, dispatch skipped
- `enforce` + detector declines: dispatch runs, runner not called
- `enforce` + runner raises: `INLINE_RUNNER_FAILED`, no dispatch fallback
- `dry_run` + detector approves: runner not called, dispatch runs, `meta.inline_decision` present
- Depth limit: depth > `DEFAULT_MAX_DEPTH` in context → detector declines → dispatch runs

## Phase D — live validation

Phase D blocked: awaiting `proceed with inline implementation`.

No GKE cluster changes were made. `NOETL_INLINE_TRIVIAL_CHILDREN` remains at `dry_run` on `noetl-worker` (helm rev 165, image `inline-cache-20260526062141`).

## Phase E — wiki + PR

**Wiki** (`repos/noetl-wiki`, commit `e960722` pushed to master):

- Updated `noetl/core/workflow/playbook/inline_execution.md`:
  - `enforce` mode behavior table updated (no longer an error).
  - New "Round B — worker inline execution" section with: runner public surface, `meta.inlined_*` key table, cancellation contract, recursion-depth boundary and dispatch fallback, `enforce` mode migration guide (`off` → `dry_run` → `enforce`), dispatched-vs-inline parity contract.
  - Cross-link to `inline_runner.md` and `round-03-result.md`.
- New `noetl/core/workflow/playbook/inline_runner.md`:
  - Full `run_inline` parameter table and `InlineResult` shape.
  - Design constraints (7 invariants).
  - Event sequence diagram.
  - Cancellation contract.
  - Step execution surface table (`python`/`mcp`/`noop`).
  - Inline failure behavior (no dispatch fallback).
  - id allocation seam documentation.
  - Operational notes.
- Both pages added to `Home.md` table and `_Sidebar.md`.

**Branch**: `kadyapam/inline-trivial-children-round-b`
**noetl commit**: `4ca1f2a3`
**Wiki commit**: `e960722`
**Draft PR**: https://github.com/noetl/noetl/pull/612 (not merged)

## Issues observed

- `repos/noetl` HEAD was `3fd1a57a` (`chore(release): version 2.101.3`) instead of `38d14a6e` as noted in the prompt — a release-only commit landed between the prompt being written and execution. Not blocking; Round B branched from `3fd1a57a`.
- `_invoke_noetl_playbook` is a sync `def` while `run_inline` is async. Resolved via sentinel-dict pattern: the sync function returns a sentinel; `execute_agent_task` (async) detects it and awaits the runner. This avoids `asyncio.get_event_loop().run_until_complete` (which errors inside a running loop) and keeps the sync/async seam explicit.
- `ai-meta` root has a pre-existing `.claude/settings.json` modification — not staged, not relevant to this work.

## Manual escalation needed

- Say `proceed with inline implementation` to unlock Phase D (live cluster validation):
  - Build image from `kadyapam/inline-trivial-children-round-b`
  - Set `NOETL_INLINE_TRIVIAL_CHILDREN=enforce` on `noetl-worker`
  - Run 5 itinerary-planner turns; record per-turn latency vs. Round A baseline (cold 7s / warm 4s)
  - Spot-check parent cancel during inline child
- Review and approve draft PR https://github.com/noetl/noetl/pull/612 before merging.
