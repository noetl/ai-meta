---
thread: 2026-06-08-server-status-endpoint-fix
round: 1
from: claude
to: codex
created: 2026-06-08T08:55:00Z
status: open
expects_result_at: round-01-result.md
wait_phrase: "ship it"
---

# noetl-server: fix premature-COMPLETED in ExecutionService::get_status

> **Predecessor:** [noetl/ai-meta#72](https://github.com/noetl/ai-meta/issues/72)
> — the umbrella ai-task issue.  Comment at
> https://github.com/noetl/ai-meta/issues/72#issuecomment-4646818393
> contains the surgical root-cause diagnosis with exact source-line
> citations and the suggested fix shape this round implements.

You are fixing three compounding bugs in
`repos/server/src/services/execution.rs::ExecutionService::get_status`
that cause the `/api/executions/{id}/status` endpoint to return
`COMPLETED` while the playbook is genuinely in-flight (commands
issued/claimed/started but not completed).

## Background

- **Operating directory:** `/Volumes/X10/projects/noetl/ai-meta`.
- **Branch base:** repos/server is on `main` at the noetl-server
  v2.61.0 release commit (`c01d3ce`).
- **Files in scope:**
  - `repos/server/src/services/execution.rs:436-573` — the
    `get_status` function.  **Primary edit site.**
- **Reproduced kind exec:** `322291053266735104` (run of
  `repos/e2e/fixtures/playbooks/playbook_composition/playbook_composition.yaml`
  on v2.61.0).  Status endpoint returned `{status: "COMPLETED",
  total_steps: 2, running_steps: 0}` while 4 `process_users`
  iterator commands were claimed + started with NO `command.completed`
  events and NO `playbook.completed` event.

### The three bugs (verbatim from the #72 root-cause diagnosis)

**Bug 1: `running_steps` SQL filter mismatch** at lines 496-498:

```rust
COUNT(DISTINCT CASE
    WHEN event_type IN ('step.enter', 'command.started') AND status = 'RUNNING'
    THEN node_name END) as running_steps,
```

Workers emit `command.started` events with `status='STARTED'`
(uppercase, past tense), not `'RUNNING'`.  The `command.claimed`
event emits `status='RUNNING'` but isn't in the filter.  Net:
`running_steps` returns 0 even when N commands are mid-execution.

**Bug 2: COMPLETED determination doesn't check in-flight commands**
at line 555:

```rust
} else if stats.1 == stats.0 && stats.0 > 0 {
    "COMPLETED".to_string()
```

If `completed_steps == total_steps` (counted via DISTINCT
`step.enter` event types), the endpoint returns COMPLETED —
without checking whether any individual step's commands are still
`issued`/`claimed`/`started` without a matching `command.completed`.
When an iterator step fires a single `step.enter` but N commands
(one per iteration) that haven't completed yet, this trips
COMPLETED.

**Bug 3 (race): `step.enter` for the next step not yet landed**
when the status endpoint is queried.  Combined with Bug 2 (no
in-flight check), the endpoint returns COMPLETED in the brief
window between the prior step's `command.completed` and the next
step's `step.enter`.

## Design contract for this round

Implement three minimal changes to make `get_status` honest about
in-flight state:

### Change 1: Add `command.claimed`/`command.started` to running_steps

Expand the `running_steps` query in the SQL block to include both
the missing event_type AND the missing status value:

```rust
running_steps:
    COUNT(DISTINCT CASE
        WHEN event_type IN ('command.claimed', 'command.started')
         AND status IN ('RUNNING', 'STARTED')
        THEN node_name END)
```

This makes the existing `progress.running_steps` field actually
reflect in-flight state.  Existing `step.enter` filter dropped —
that event fires once per step, not per command, so it's
misleading for iterator steps.

### Change 2: Cross-check `noetl.command` for in-flight commands

Add a fourth SQL query: count commands whose status is NOT
terminal (i.e. PENDING / RUNNING):

```rust
let in_flight_commands: (i64,) = sqlx::query_as(
    r#"
    SELECT COUNT(*) FROM noetl.command
    WHERE execution_id = $1
      AND status NOT IN ('COMPLETED', 'FAILED', 'CANCELLED', 'completed', 'failed', 'cancelled')
    "#,
)
.bind(execution_id)
.fetch_one(self.pool_for(execution_id))
.await?;
```

Use `pool_for(execution_id)` to keep sharding consistency.

### Change 3: Guard the COMPLETED branch

At line 555, add the in-flight check:

```rust
} else if stats.1 == stats.0
    && stats.0 > 0
    && in_flight_commands.0 == 0
{
    "COMPLETED".to_string()
```

Now COMPLETED only fires when:
- All known steps are completed (event-log signal: stats.1 == stats.0)
- Zero commands are in-flight (command-table signal: in_flight_commands.0 == 0)
- Neither half can prematurely trip the verdict alone.

### Why both signals

- Event-log signal alone (Bug 2) trips before iterator commands
  finish because `step.enter` counts steps, not commands.
- Command-table signal alone could be misled by a stale
  `noetl.command` projection (the table may lag the event log).
- Requiring BOTH means: "the orchestrator says no more steps to
  start, AND there are no commands still running" — closer to
  Python's parity behaviour.

### Out of scope for this round

- The terminal-event short-circuit at lines 466-481 stays untouched —
  it's correct; `playbook.completed` is the definitive signal when
  it lands.
- The `noetl.execution` table not being populated by the Rust
  orchestrator (separate gap surfaced during the diagnosis) — that's
  a different code path; file a separate issue if it bites later.
- Fixing the underlying *worker stall* on nested
  `task_sequence` → `tool: kind: playbook` dispatch — that's the
  real reason the 4 commands never completed; separate sub-issue.

This round only fixes the **status endpoint's verdict** so it
no longer LIES about in-flight state.  The underlying playbook
will still get stuck (worker bug), but the status endpoint will
correctly report `RUNNING` with non-zero `in_flight_commands`
(visible via `running_steps`) so polling tools / CI gates won't
be fooled.

## Phases

### Phase A — read-only survey (unattended)

1. Read `repos/server/src/services/execution.rs:436-573` end-to-end.
   Confirm line numbers + the four SQL queries (event existence,
   terminal event, stats, current_step, is_cancelled).
2. Read line 555 in context — confirm the cascade order
   (terminal → cancelled → failed_steps > 0 → completed → RUNNING).
3. Grep for any test at the bottom of the file that pins
   `get_status` behaviour — list test names + line numbers.
4. Grep `noetl.command` schema in `repos/server/src/db/queries/`
   to confirm the `status` column values are what the new query
   expects.  Specifically: does the worker write
   `'COMPLETED'` (uppercase) or `'completed'` (lowercase) when it
   marks a command done?  Match the casing used today; report
   what you find.
5. Capture findings in your final report.

### Phase B — implement + tests + clippy + release build (unattended)

> Run unattended.  No remote writes.  Commit locally on a feature branch.

6. Create branch `feat/status-endpoint-honest-in-flight-check` on
   `repos/server` (off current `main`).
7. Apply the three changes from the Design contract above:
   - Update the `running_steps` query in the SQL block to use
     `('command.claimed', 'command.started')` + `('RUNNING', 'STARTED')`.
   - Add a new `in_flight_commands` query against
     `noetl.command` (use the same `pool_for(execution_id)`).
   - Update the COMPLETED branch at line 555 to require
     `in_flight_commands.0 == 0`.
8. Add unit tests.  The existing `determine_status_*` tests
   (around line 848+) are the pattern.  Add:
   - `test_get_status_returns_running_when_command_in_flight_despite_step_counts_equal`
     — fixture: 2 steps both with `command.completed | success`,
     plus 1 row in `noetl.command` with status `PENDING`.  Assert
     the endpoint returns `RUNNING`, not `COMPLETED`.
   - `test_get_status_counts_running_command_started_status`
     — fixture: 1 step with `step.enter` + `command.started`
     (status='STARTED').  Assert `progress.running_steps == 1`.
   - `test_get_status_counts_running_command_claimed_status`
     — same but `command.claimed` (status='RUNNING').
     Assert `progress.running_steps == 1`.
   - `test_get_status_completed_only_when_no_in_flight`
     — terminal event present + all steps complete + zero
     in-flight commands.  Assert COMPLETED.
9. `cd repos/server && cargo fmt && cargo build --release` —
   must be clean.
10. `cargo test --lib` — must pass entirely; record the count
    (was 594/0 pre-change).
11. `cargo clippy --lib --tests --release -- -D warnings` — zero
    new errors in `services/execution.rs`.
12. Commit locally with a `fix:` prefix message citing
    `Closes noetl/ai-meta#72` in the body.  Stage all changes
    under `repos/server` only.  Do NOT push.

### Phase C — push branch + open PR (gated on `ship it`)

> ***Run only after explicit human go-ahead. Wait phrase: `ship it`.***

13. `git push -u origin feat/status-endpoint-honest-in-flight-check`
    on `repos/server`.
14. Open the PR via `gh pr create` with:
    - Title: `fix(status): honest in-flight check so /api/executions/{id}/status doesn't return COMPLETED while commands are pending`
    - Body citing `Closes noetl/ai-meta#72` in the footer.
    - Test plan section listing the 4 new unit tests + the kind
      re-val expectation (re-run `playbook_composition.yaml`,
      observe status stays `RUNNING` while `process_users`
      commands are pending).
15. Comment on noetl/ai-meta#72 with the PR URL.
16. **STOP.**  Do not roll the kind deployment.  Claude owns the
    follow-up.

## FINAL REPORT

Always emit this, even on early STOP.  Frontmatter:

```yaml
---
thread: 2026-06-08-server-status-endpoint-fix
round: 1
from: codex
to: claude
created: <ISO8601 UTC>
in_reply_to: round-01-prompt.md
status: complete | partial | blocked
---
```

Then:

```markdown
## Phase A — read-only survey
- Line numbers + cascade order confirmed.
- Existing test names + line numbers listed.
- noetl.command status casing observed (uppercase / lowercase).

## Phase B — implement + tests + build
- Diff summary (lines added/removed, files touched).
- Test count: `<N> passed / 0 failed` (was 594/0).
- Release build outcome.
- Clippy outcome.
- Local commit SHA.

## Phase C — open PR
- Either: PR URL + comment URL.  OR: `Phase C blocked: awaiting ship it`.

## Issues observed
- Anything surprising during the survey or implementation.

## Manual escalation needed
- Claude follow-ups after PR merges:
  - Wait for release-please tag (likely v2.62.0).
  - Build noetl-server image, kind reload.
  - Re-run `playbook_composition/playbook_composition.yaml` —
    expect status stays RUNNING while process_users commands
    are pending; in_flight_commands > 0; running_steps > 0.
  - Bump ai-meta pointer + close noetl/ai-meta#72.
  - Optional follow-up: file separate issue for the underlying
    worker stall on nested task_sequence → playbook tool dispatch.
```

## Hard rules for this thread

- Never push to `origin/main` on any repo.
- Never force-push.
- Never merge PRs yourself.
- Respect `AGENTS.md` and the rules under `agents/rules/`.
- Do NOT bump the noetl-server version in `Cargo.toml` — release-please owns versioning; `fix:` triggers the PATCH bump.
- Do NOT touch Python code.  Reference-only.
- Do not store secrets in any file (public repo).
- If a step's preconditions aren't met, stop and report — don't improvise around blockers.
