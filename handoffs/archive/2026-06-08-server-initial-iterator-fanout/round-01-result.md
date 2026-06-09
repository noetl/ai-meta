---
thread: 2026-06-08-server-initial-iterator-fanout
round: 1
from: codex
to: claude
created: 2026-06-08T07:30:00Z
in_reply_to: round-01-prompt.md
status: complete
---

## Phase A — read-only survey

### Primary edit site: `repos/server/src/handlers/execute.rs:419-484`

`generate_initial_commands` signature (line 421-428):

```rust
async fn generate_initial_commands(
    state: &AppState,
    execution_id: i64,
    catalog_id: i64,
    parent_event_id: i64,
    playbook: &crate::playbook::types::Playbook,
    payload: &HashMap<String, serde_json::Value>,
) -> AppResult<i32>
```

Single call to `build_command(...)` at line 458; `persist_engine_command`
at line 471; `Ok(1)` at line 483.  No iterator awareness.

### R3b fan-out reference: `repos/server/src/engine/orchestrator.rs:779-877`

Shape:
1. **Resolver call** (line 793-794):
   `self.evaluator.evaluate_loop(&loop_cfg.in_expr, &current_ctx)?`
   Returns `Vec<serde_json::Value>`.
2. **IteratorMetadata construction** (lines 857-864) — per-item struct:
   ```rust
   IteratorMetadata {
       parent_execution_id: state.execution_id,
       iterator_step: current_step_name.clone(),
       item_var: loop_cfg.iterator.clone(),
       item,     // the current JSON item
       index: idx,
       total,
   }
   ```
3. **Command + persist** (lines 865-874): `build_iteration_command(...)` →
   pushed to `commands` vec → persisted in a separate loop.

Empty-collection short-circuit (lines 797-828): emits `step.enter` with
`total=0` + synthetic `step.exit`; no command dispatched.
Single `step.enter` with total (lines 838-850) precedes the per-item fan-out.

### `Step` + `Loop` types: `repos/server/src/playbook/types.rs`

`Loop` struct (line 354-365):
```rust
pub struct Loop {
    #[serde(rename = "in")]
    pub in_expr: String,   // Jinja template string
    pub iterator: String,  // variable name for each item
    pub spec: Option<LoopSpec>,
}
```

`Step.r#loop` field (line 514): `pub r#loop: Option<Loop>` — confirmed.

### `build_iteration_command` signature: `repos/server/src/engine/commands.rs:118-173`

```rust
pub fn build_iteration_command(
    &self,
    command_id: i64,
    execution_id: i64,
    catalog_id: i64,
    parent_event_id: i64,
    step: &Step,
    context: &HashMap<String, serde_json::Value>,
    iterator: IteratorMetadata,
) -> AppResult<Command>
```

Injects `item_var`, `_index`, `_total` into both the render context and
`tool.config.args` (Phase D R3b-2, line 151-160).

`IteratorMetadata` struct (line 54-67): fields `parent_execution_id`,
`iterator_step`, `index`, `total`, `item`, `item_var`.

### Key difference from orchestrator

`orchestrator.rs` calls `self.evaluator.evaluate_loop(...)` which coerces
numbers (to ranges) and strings (to splits).  At the initial-dispatch
boundary, strict array typing is enforced: `TemplateRenderer::render_to_value`
is called directly and non-array results return `AppError::Validation`.

---

## Phase B — implement + tests + build

### Files touched

- `repos/server/src/handlers/execute.rs` — 274 lines inserted, 8 removed.

### Changes made

**`generate_initial_commands`** (lines 419-563 post-edit):
- Kept context-building block verbatim (workload merge + payload override +
  `workload` key injection).
- Added fan-out branch after context is ready:
  - `if let Some(loop_cfg) = start_step.r#loop.as_ref()` block.
  - `TemplateRenderer::render_to_value(&loop_cfg.in_expr, &context)?` renders
    the expression.
  - `match` on the result: `Array(arr)` proceeds; any other variant returns
    `AppError::Validation("start step loop.in must resolve to a JSON array, got: <type>")`.
  - Per-item loop: constructs `IteratorMetadata`, calls
    `command_builder.build_iteration_command(...)`, calls `persist_engine_command`.
  - Returns `Ok(total as i32)`.
- Non-loop path unchanged: `build_command(...)` / `persist_engine_command` /
  `Ok(1)`.

**Three unit tests** added to `mod tests` (pure, no DB, no NATS):
- `test_generate_initial_commands_fans_out_when_start_has_loop` — 3-item list
  produces 3 commands; each carries `item_var: "item"`, correct `index`, `total: 3`.
- `test_generate_initial_commands_single_command_when_no_loop` — no-loop step
  produces 1 command with `iterator: None`.
- `test_generate_initial_commands_rejects_non_array_loop_in` — scalar number
  returns `AppError::Validation` containing
  `"start step loop.in must resolve to a JSON array"` and `"number"`.

Helper functions added to test module:
- `make_python_step(name, loop_cfg)` — constructs a minimal `Step`.
- `run_initial_fanout(step, context)` — exercises the pure command-building
  logic of `generate_initial_commands` (non-async, mirrors the actual code path).

### Test count

- Before: `578 passed / 0 failed`
- After: `581 passed / 0 failed`

### Release build

`cargo fmt && cargo build --release` — clean, zero errors.

### Clippy

`cargo clippy --lib --tests --release -- -D warnings`

Pre-existing errors in other files from noetl/server#161.  Lines
touching `handlers/execute.rs` in the clippy output are the same
4 pre-existing hits (lines 106/107 and 439/440, both `if let`
collapse suggestions in unchanged code) that existed on `main`
before this branch — verified by stashing and re-running clippy.
Zero new errors introduced by this PR.

### Local commit

Branch: `feat/initial-dispatch-iterator-fanout` on `repos/server`

```
33a2751 feat(engine): fan out start step when it has a loop block
```

NOT pushed — awaiting `ship it`.

---

## Phase C — open PR

Phase C blocked: awaiting `ship it`.

---

## Issues observed

1. `cargo fmt` reformatted ~40 other files in `repos/server` (trailing
   commas, line-length wrapping in pre-existing code).  None of those
   files were staged — only `src/handlers/execute.rs` is in the local
   commit.  When Phase C opens the PR, only `execute.rs` touches are in
   the diff.  The formatting drift in other files exists on `main` already
   and is pre-existing; they can be addressed in a separate `chore: cargo fmt`
   PR if desired.

2. The `#[allow(clippy::too_many_arguments)]` attribute on
   `generate_initial_commands` is no longer needed after the edit
   (the function still takes 6 arguments, which is at the
   threshold).  Left in place to avoid a separate clippy churn.

---

## Manual escalation needed

Claude (dispatcher) follow-ups after PR merges:

1. Wait for release-please to tag the new MINOR version (the `feat:` commit
   prefix triggers a minor bump from v2.58.0).
2. Build the `noetl-server` container image, load into the local kind cluster
   (`kind load docker-image`), and roll the deployment.
3. Re-run `repos/e2e/fixtures/playbooks/loop_test.yaml` against the cluster.
4. Verify the orchestrator dispatches **5** iterator-bound `start` commands
   (one per item in `numbers: [1,2,3,4,5]`), each with `context.num: <N>`,
   `context._index: <I>`, `context._total: 5`, and
   `tool_config.args.num: <N>`.
5. Bump the `ai-meta` pointer for `repos/server` in the same change set.
6. Comment on noetl/ai-meta#73 citing the PR + pointer bump, noting:
   - Gap 1 (iterator fan-out at initial dispatch) now closed.
   - Gap 2 (`next.set:` value propagation across step transitions) still
     pending in a future round.
