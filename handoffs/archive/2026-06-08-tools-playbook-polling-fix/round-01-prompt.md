---
thread: 2026-06-08-tools-playbook-polling-fix
round: 1
from: claude
to: codex
created: 2026-06-08T16:15:00Z
status: open
expects_result_at: round-01-result.md
wait_phrase: "ship it"
---

# noetl-tools: fix PlaybookTool polling terminal-field shape mismatch

> **Predecessor:** [noetl/ai-meta#75](https://github.com/noetl/ai-meta/issues/75)
> — the umbrella ai-task issue.  This round closes it.
>
> Related cleanup: [noetl/ai-meta#72](https://github.com/noetl/ai-meta/issues/72)
> fixed the status endpoint's side of the same bug family
> (status endpoint now correctly reports RUNNING for in-flight
> commands).  This round fixes the consumer side: PlaybookTool
> reads the right fields out of the status response.

You are replacing one boolean-field check with a string-status
check in `PlaybookTool::execute`.  The current code looks for
`payload.completed: bool` / `payload.failed: bool` but the
`/api/executions/{id}/status` endpoint returns
`payload.status: string` (values `COMPLETED` / `FAILED` /
`CANCELLED` / `RUNNING`).  Net: the polling loop never terminates
short of the 300s timeout — child playbooks dispatched via
`tool: kind: playbook` with `return_step: end` always time out.

## Background

- **Operating directory:** `/Volumes/X10/projects/noetl/ai-meta`.
- **Branch base:** repos/tools is on `main` at the noetl-tools
  v2.24.0 release commit (`b6b80ce`).
- **Files in scope:**
  - `repos/tools/src/tools/playbook.rs:220-232` — the polling-loop
    terminal check.  **Only edit site.**
- **Reference (server status endpoint, read-only):**
  - `repos/server/src/services/execution.rs::ExecutionStatus`
    struct + `get_status` function — confirms the response shape:

    ```json
    {
      "execution_id": 12345,
      "status": "COMPLETED",
      "current_step": null,
      "progress": {
        "total_steps": 4,
        "completed_steps": 4,
        "running_steps": 0,
        "failed_steps": 0
      },
      "is_cancelled": false
    }
    ```

### Current code (buggy)

`repos/tools/src/tools/playbook.rs:220-232`:

```rust
if let Some(payload) = status_payload {
    let completed = payload
        .get("completed")
        .and_then(|v| v.as_bool())
        .unwrap_or(false);
    let failed = payload
        .get("failed")
        .and_then(|v| v.as_bool())
        .unwrap_or(false);
    if completed || failed {
        return Ok(ToolResult::success(payload));
    }
}
```

`payload.get("completed")` / `payload.get("failed")` always return
`None` because the keys don't exist in the response.  `.as_bool()`
on `None` is `None`, `.unwrap_or(false)` is `false`, terminal check
is always false, loop runs until 300s timeout.

## Design contract for this round

Replace the two boolean lookups with a string-based status check
that mirrors the server's terminal-state enum.  Handle:

- `status == "COMPLETED"` → terminal-success
- `status == "FAILED"` → terminal-failure
- `status == "CANCELLED"` → terminal-cancelled
- `is_cancelled: true` → also terminal-cancelled (the status field
  may briefly remain `"RUNNING"` while `is_cancelled` flips first;
  honor either signal)
- Anything else (RUNNING / no status key) → keep polling

Suggested implementation (illustration, not literal — adapt to
the existing style):

```rust
if let Some(payload) = status_payload {
    let status_str = payload
        .get("status")
        .and_then(|v| v.as_str())
        .unwrap_or("");
    let is_cancelled = payload
        .get("is_cancelled")
        .and_then(|v| v.as_bool())
        .unwrap_or(false);
    let terminal = matches!(status_str, "COMPLETED" | "FAILED" | "CANCELLED")
        || is_cancelled;
    if terminal {
        return Ok(ToolResult::success(payload));
    }
}
```

Notes on the result-shape we return:

- The current code returns `ToolResult::success(payload)`
  regardless of whether the underlying terminal was success or
  failure.  Preserve that shape — downstream consumers (the
  task_sequence / orchestrator) read the payload's structured
  fields; they don't rely on `ToolResult::error` for failed-child
  playbooks.  If you want to be stricter (return `Err` for
  FAILED / CANCELLED), that's a behaviour change — keep it out
  of scope for this round; file a follow-up.

## Phases

### Phase A — read-only survey (unattended)

1. Read `repos/tools/src/tools/playbook.rs:100-235` end-to-end.
   Confirm the polling loop boundaries + the surrounding
   `started.elapsed()` timeout guard.
2. Confirm the response-shape from
   `repos/server/src/services/execution.rs::ExecutionStatus` is
   exactly as described in the prompt body.  Note any deviation.
3. Grep for existing unit tests on `PlaybookTool` in
   `repos/tools/src/tools/playbook.rs` — list test names + line
   numbers.  Capture findings.

### Phase B — implement + tests + clippy + release build (unattended)

> Run unattended.  No remote writes.  Commit locally on a feature branch.

4. Create branch `fix/playbook-tool-status-terminal-check` on
   `repos/tools` (off current `main`).
5. Apply the change at the polling-loop terminal check.  Replace
   the two boolean lookups with the string-based status check
   from the design contract above.  Include the `is_cancelled`
   fallback signal.
6. Add unit tests.  Suggested:
   - `test_playbook_tool_terminates_on_completed_status` — mock
     the HTTP response with `{"status": "COMPLETED"}` and assert
     the polling loop exits within one iteration.
   - `test_playbook_tool_terminates_on_failed_status` — same with
     `"FAILED"`.
   - `test_playbook_tool_terminates_on_cancelled_status` — same
     with `"CANCELLED"`.
   - `test_playbook_tool_terminates_on_is_cancelled_flag` — mock
     response with `{"status": "RUNNING", "is_cancelled": true}`;
     assert the loop exits.
   - `test_playbook_tool_keeps_polling_on_running_status` — mock
     response with `{"status": "RUNNING"}`; assert the loop does
     NOT exit (you can pin this via a short-timeout fixture or by
     asserting the function returns the timeout result after the
     elapsed-guard fires).

   Use whatever mock-HTTP pattern the existing test code uses (if
   none, `mockito` or a hand-rolled trait object — match the
   surrounding crate's style).
7. `cd repos/tools && cargo fmt && cargo build --release` — clean.
8. `cargo test --lib` — must pass entirely.  Record `<total> passed
   / 0 failed` count (was 281/0 pre-#74 work; the noetl-tools repo
   may have shifted since then — record what you see).
9. `cargo clippy --lib --tests --release -- -D warnings` — zero
   new errors in `tools/playbook.rs`.  Pre-existing debt from
   [noetl/tools#42](https://github.com/noetl/tools/issues/42) in
   other files is out-of-scope.
10. Commit locally with a `fix:` prefix message citing
    `Closes noetl/ai-meta#75` in the body.  Stage all changes
    under `repos/tools` only.  Do NOT push.

### Phase C — push branch + open PR (gated on `ship it`)

> ***Run only after explicit human go-ahead. Wait phrase: `ship it`.***

11. `git push -u origin fix/playbook-tool-status-terminal-check`
    on `repos/tools`.
12. Open PR via `gh pr create` with:
    - Title: `fix(playbook): terminate polling on status: COMPLETED/FAILED/CANCELLED`
    - Body citing `Closes noetl/ai-meta#75`.
    - Test plan section listing the new unit tests + the kind
      re-val expectation (re-run `playbook_composition.yaml`,
      verify each `process_users` iteration's child playbook
      returns within the child's actual runtime instead of
      timing out at 300s).
13. Comment on noetl/ai-meta#75 with the PR URL.
14. **STOP.**  Do not bump the noetl-tools version in `Cargo.toml`
    — release-please owns versioning; `fix:` prefix triggers
    PATCH bump.  Do not roll the kind deployment.  Claude owns
    that follow-up.

## FINAL REPORT

Always emit this, even on early STOP.  Write it as the body of
`expects_result_at` with frontmatter:

```yaml
---
thread: 2026-06-08-tools-playbook-polling-fix
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
- Polling loop boundaries + timeout guard confirmed.
- Server status endpoint response shape confirmed.
- Existing test names + line numbers listed.

## Phase B — implement + tests + build
- Diff summary (lines added/removed, files touched).
- Test count: `<N> passed / 0 failed`.
- Release build outcome.
- Clippy outcome.
- Local commit SHA.

## Phase C — open PR
- Either: PR URL + comment URL.  OR: `Phase C blocked: awaiting ship it`.

## Issues observed
- Anything surprising during the implementation.

## Manual escalation needed
- Claude follow-ups after PR merges:
  - Wait for release-please to tag (likely v2.24.1).
  - Wait for crates.io publish.
  - Bump noetl-worker's noetl-tools dep 2.24 → 2.24.1 (or
    confirm caret-range already covers it).
  - Build worker image, kind reload.
  - Re-run playbook_composition.yaml — child playbooks should
    now return within their actual runtime instead of timing
    out at 300s.
  - Bump ai-meta pointers + close noetl/ai-meta#75.
```

## Hard rules for this thread

- Never push to `origin/main` on any repo.
- Never force-push.
- Never merge PRs yourself.
- Respect `AGENTS.md` and the rules under `agents/rules/`.
- Do NOT bump the noetl-tools version in `Cargo.toml` —
  release-please owns versioning; `fix:` triggers the PATCH bump.
- Do NOT touch Python code.  Reference-only.
- Do not store secrets in any file (public repo).
- If a step's preconditions aren't met, stop and report — don't
  improvise around blockers.
