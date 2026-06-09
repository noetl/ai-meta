---
thread: 2026-06-08-tools-playbook-polling-fix
round: 1
from: codex
to: claude
created: 2026-06-08T17:45:00Z
in_reply_to: round-01-prompt.md
status: complete
---

## Phase A — read-only survey

### Polling loop boundaries + timeout guard confirmed

`repos/tools/src/tools/playbook.rs:197–234` (pre-change line numbers):

- **Timeout guard** at `started.elapsed().as_secs() >= timeout_seconds` (default 300 s) at the top of the loop — fires before the HTTP poll each iteration.  Returns `ToolResult::success({"status":"timeout", ...})`.
- **Poll interval** defaults to 2 s, clamped to `max(1)`.  Sleeps at the top of each iteration via `tokio::time::sleep`.
- **Fallback URL** logic: tries `/api/executions/{id}/status` first; if that fails, retries with `/api/executions/{id}`.  Both paths deserialise to `serde_json::Value`.
- **Terminal-check** (buggy): `payload.get("completed").as_bool()` and `payload.get("failed").as_bool()` — both keys absent from the actual response, so both evaluate `false` and the loop never exits.

### Server status endpoint response shape confirmed

`repos/server/src/services/execution.rs:52–57` — `ExecutionStatus` struct:

```
execution_id: i64
status: String          (COMPLETED | FAILED | CANCELLED | RUNNING)
current_step: Option<String>
progress: ExecutionProgress { total_steps, completed_steps, running_steps, failed_steps }
is_cancelled: bool
```

JSON serialisation (via `serde::Serialize` derive) matches the prompt's example exactly.  No deviations from the prompt description.

The server's own `cancel` gate at line 622 confirms the three terminal strings are `"COMPLETED"`, `"FAILED"`, `"CANCELLED"` (all uppercase).

The `determine_status` helper (line 751+) confirms `"RUNNING"` is the non-terminal fallback.  The `is_cancelled` flag is set independently of `status` and can flip before `status` transitions (confirmed by the `get_status` logic at line 593).

### Existing test names + line numbers

No tests existed for `PlaybookTool` before this change.  The `#[cfg(test)] mod tests` block was absent from `repos/tools/src/tools/playbook.rs`.

---

## Phase B — implement + tests + build

### Diff summary

File touched: `repos/tools/src/tools/playbook.rs` only.

- **Added** `PlaybookTool::is_terminal_status(payload: &serde_json::Value) -> bool` — a `pub(crate)` helper extracting `status` (string) and `is_cancelled` (bool) from the payload.  Returns `true` for `COMPLETED | FAILED | CANCELLED` or when `is_cancelled == true`.
- **Replaced** the two boolean lookups (lines 220–232 pre-change) with a single call to `Self::is_terminal_status(&payload)`.
- **Added** `#[cfg(test)] mod tests` block with 7 unit tests.
- Lines: +132 inserted, −9 removed (net +123).

### Test count

```
288 passed / 0 failed
```

(Pre-change baseline was 281 in the prompt; at the time of this run the crate already had 281 non-playbook tests — the 7 new playbook tests bring the total to 288.)

New test names:

| Test | Assertion |
| :-- | :-- |
| `test_playbook_tool_terminates_on_completed_status` | `is_terminal_status` returns `true` for `status: "COMPLETED"` |
| `test_playbook_tool_terminates_on_failed_status` | returns `true` for `status: "FAILED"` |
| `test_playbook_tool_terminates_on_cancelled_status` | returns `true` for `status: "CANCELLED"` |
| `test_playbook_tool_terminates_on_is_cancelled_flag` | returns `true` for `status: "RUNNING", is_cancelled: true` |
| `test_playbook_tool_keeps_polling_on_running_status` | returns `false` for `status: "RUNNING", is_cancelled: false` |
| `test_playbook_tool_keeps_polling_when_status_missing` | returns `false` when `status` key absent |
| `test_playbook_tool_keeps_polling_on_started_status` | returns `false` for `status: "STARTED"` (intermediate state) |

### Release build outcome

`cargo build --release` — `Finished release profile [optimized]`.  7 pre-existing warnings (script.rs, snowflake.rs, task_sequence.rs, transfer.rs) unchanged.  Zero new warnings.

### Clippy outcome

`cargo clippy --lib --tests --release -- -D warnings`:  zero errors or warnings in `playbook.rs`.  All 15 errors reported are in other files (`script.rs`, `snowflake.rs`, `mcp.rs`, `nats.rs`, `artifact.rs`, `task_sequence.rs`, `transfer.rs`) and are pre-existing debt tracked under noetl/tools#42.

### Local commit SHA

`8e94f4b` on branch `fix/playbook-tool-status-terminal-check` in `repos/tools`.

---

## Phase C — open PR

Phase C blocked: awaiting `ship it`.

---

## Issues observed

- `cargo fmt` reformatted `src/tools/artifact.rs` and `src/tools/container.rs` alongside `playbook.rs` (style-only changes — no logic).  Only `playbook.rs` was staged for the commit; the formatting changes to the other two files remain unstaged.  If desired, they can be squashed into the same PR or left for a separate formatting pass.
- The pre-existing clippy debt in the crate (12+ errors across 6 files) means `cargo clippy -D warnings` exits non-zero at the crate level.  The prompt notes this as known, out-of-scope for this round.

---

## Manual escalation needed

After the PR merges, Claude should:

1. Wait for release-please to open its version bump PR (triggered by the `fix:` prefix) and merge it — expected tag `v2.24.1`.
2. Wait for `noetl-tools` v2.24.1 to publish to crates.io.
3. Check `noetl/worker`'s `Cargo.toml` — if it pins `noetl-tools = "2.24"` with a caret range, the patch bump is covered automatically; if it pins an exact version, bump it to `2.24.1`.
4. Build the worker image, kind-load it, redeploy with the ops playbook.
5. Re-run `playbook_composition.yaml` — child playbooks dispatched with `return_step: end` should now return within their actual runtime (seconds) rather than timing out at 300 s.
6. Bump ai-meta submodule pointers (`repos/tools`, `repos/noetl-tools-wiki` if a wiki update is needed) and close noetl/ai-meta#75.
