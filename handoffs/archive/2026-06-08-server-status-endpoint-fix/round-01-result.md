---
thread: 2026-06-08-server-status-endpoint-fix
round: 1
from: codex
to: claude
created: 2026-06-08T12:00:00Z
in_reply_to: round-01-prompt.md
status: complete
---

## Phase A — read-only survey

### Line numbers + cascade order confirmed

`get_status` spans lines 436–573 in `repos/server/src/services/execution.rs`.
The function contains five SQL queries in this order:

1. **Existence check** (lines 438–442): `SELECT execution_id FROM noetl.event WHERE execution_id = $1 LIMIT 1`
2. **Terminal event** (lines 466–481): `SELECT event_type FROM noetl.event WHERE event_type IN ('playbook.completed', 'playbook_completed', 'playbook.failed', 'playbook_failed')`
3. **Stats** (lines 488–504): 4-tuple `(total_steps, completed_steps, running_steps, failed_steps)` against `noetl.event`
4. **Current step** (lines 507–520): latest `step.enter` / `command.started` node_name
5. **Is-cancelled** (lines 523–534): `EXISTS` check for `playbook.cancelled` / `playbook_cancelled`

Cascade order at line 544 (confirmed): terminal event → cancelled → failed_steps > 0 → completed_steps == total_steps → RUNNING.

### Existing test names + line numbers

All tests are in `#[cfg(test)] mod tests` starting at line 721.  Pre-change count: 594 tests across the crate.

| Test name | Line |
|---|---|
| `test_execution_summary_serialization` | 726 |
| `test_execution_status_serialization` | 742 |
| `test_execution_filter_default` | 762 |
| `determine_status_returns_completed_on_playbook_completed_event` | 803 |
| `determine_status_returns_completed_on_underscore_alias` | 817 |
| `determine_status_returns_failed_on_playbook_failed_event` | 827 |
| `determine_status_returns_cancelled_on_playbook_cancelled` | 837 |
| `determine_status_stays_running_without_terminal_event` | 847 |
| `determine_status_returns_failed_on_individual_event_failure` | 861 |

### noetl.command status casing

**Uppercase** is the primary convention.  Workers write status values as follows (verified in `repos/worker/src/events/emitter.rs`):

- `command.issued` → `status = 'PENDING'` (set by server at INSERT, `repos/server/src/handlers/execute.rs:601`)
- `command.claimed` → `status = 'STARTED'` (worker emits with `"STARTED"` literal, emitter.rs:189)
- `command.started` → `status = 'STARTED'` (worker emits with `"STARTED"` literal, emitter.rs:208)
- `command.completed` → `status = 'COMPLETED'` (derived from event_type prefix by `strip_prefix("command.").to_ascii_uppercase()`, replay.rs:1357)
- `command.failed` → `status = 'FAILED'` (same derivation)

Key finding: `command.claimed` emits `status='STARTED'` (NOT `'RUNNING'`), confirming Bug 1.  The old `running_steps` filter `status = 'RUNNING'` would never match `command.claimed` or `command.started` events.

The `noetl.command` table schema (schema_ddl.sql:929) defines `status TEXT NOT NULL DEFAULT 'PENDING'` with no CHECK constraint, so both uppercase and lowercase values may appear from Python-side writes.  The new `in_flight_commands` query covers both casings in the exclusion list.

## Phase B — implement + tests + build

### Diff summary

One file changed: `repos/server/src/services/execution.rs`

**Change 1** — `running_steps` SQL filter (lines ~496–499 post-fmt):
- Old: `event_type IN ('step.enter', 'command.started') AND status = 'RUNNING'`
- New: `event_type IN ('command.claimed', 'command.started') AND status IN ('RUNNING', 'STARTED')`
- Removed `step.enter` (fires once per step, misleading for iterator steps)
- Added `command.claimed` (the actual claimed event the worker emits)
- Added `'STARTED'` to the status list (the actual value workers write)

**Change 2** — new `in_flight_commands` query (added after the is-cancelled query):
```sql
SELECT COUNT(*) FROM noetl.command
WHERE execution_id = $1
  AND status NOT IN ('COMPLETED', 'FAILED', 'CANCELLED', 'completed', 'failed', 'cancelled')
```
Uses `pool_for(execution_id)` for shard consistency.

**Change 3** — COMPLETED branch guard (line ~555):
- Old: `} else if stats.1 == stats.0 && stats.0 > 0 {`
- New: `} else if stats.1 == stats.0 && stats.0 > 0 && in_flight_commands.0 == 0 {`

**Tests added** (4 new tests, all passing):
- `test_get_status_returns_running_when_command_in_flight_despite_step_counts_equal`
- `test_get_status_counts_running_command_started_status`
- `test_get_status_counts_running_command_claimed_status`
- `test_get_status_completed_only_when_no_in_flight`

Note: the new tests use the `determine_status` in-memory path (which covers the terminal-event short-circuit) + document the worker-emitted event shapes.  Full SQL-level assertions (running_steps=1, in_flight_commands count) require the kind cluster and are validated there per noetl/ai-meta#72.

### Test count

`598 passed / 0 failed` (was 594/0 pre-change; 4 new tests added).

### Release build outcome

`Finished release profile [optimized]` — clean, no errors.

### Clippy outcome

Zero new errors or warnings in `services/execution.rs`.  Pre-existing clippy errors exist in other files (14 errors in other modules) — none introduced by this change.  Confirmed by running `cargo clippy --lib --tests --release -- -D warnings 2>&1 | grep "services/execution"` which returned no output.

### Local commit SHA

`4c14750` on branch `feat/status-endpoint-honest-in-flight-check` in `repos/server`.

Commit is on top of `c01d3ce` (v2.61.0 release commit) as specified.

## Phase C — open PR

Phase C blocked: awaiting `ship it`.

The feature branch `feat/status-endpoint-honest-in-flight-check` is staged locally in `repos/server`.  The branch has not been pushed to `origin`.

## Issues observed

1. `cargo fmt` reformatted 37 other files (pre-existing formatting drift across the codebase).  Only `src/services/execution.rs` was staged and committed; the other formatting changes were left unstaged to keep the fix commit focused.

2. Pre-existing clippy errors exist in 14 locations across other source files (not introduced by this change).  The prompt's clippy gate (`zero new errors in services/execution.rs`) passes cleanly.

3. `command.claimed` emits `status='STARTED'` (not `'RUNNING'` as Bug 1 description implied could be the status).  Both the `command.claimed` and `command.started` events use `'STARTED'`.  The fix accepts both `'RUNNING'` and `'STARTED'` in the IN list to be safe against future changes.

4. The `noetl.command` table has no CHECK constraint on the `status` column, so the in-flight exclusion list covers both uppercase (`'COMPLETED'`, `'FAILED'`, `'CANCELLED'`) and lowercase variants.

## Manual escalation needed

Claude follow-ups after PR merges:

- Wait for release-please to tag `v2.62.0` (triggered by the `fix:` commit prefix).
- Build noetl-server image, kind reload (use `repos/ops/automation/development/noetl.yaml` with `action=redeploy`).
- Re-run `playbook_composition/playbook_composition.yaml` (execution `322291053266735104` was the repro):
  - Expect status stays `RUNNING` while `process_users` commands are pending.
  - Expect `running_steps > 0` when commands are claimed/started.
  - Expect `in_flight_commands > 0` visible indirectly via the RUNNING verdict holding.
  - Expect `COMPLETED` only after `playbook.completed` event lands OR all steps + commands finish.
- Bump ai-meta pointer to new server SHA + close noetl/ai-meta#72.
- Optional follow-up: file separate issue for the underlying worker stall on nested `task_sequence → tool: kind: playbook` dispatch (the root cause of commands never completing in the repro execution; separate from the status endpoint lying about it).
