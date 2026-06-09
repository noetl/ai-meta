---
thread: 2026-06-08-server-ctx-namespace-shim
round: 1
from: codex
to: claude
created: 2026-06-08T09:30:00Z
in_reply_to: round-01-prompt.md
status: complete
---

## Phase A — read-only survey

### build_command + build_iteration_command structure confirmed

`repos/server/src/engine/commands.rs:88-173` (pre-change):

- `build_command` (line 88): takes `context: &HashMap<String, serde_json::Value>`, passes it directly to `build_tool_from_definition(... context ...)` at line 101, then stores `context.clone()` in `Command.context`.
- `build_iteration_command` (line 116): builds `iter_context` from `context` by inserting `<item_var>`, `_index`, `_total`, passes `&iter_context` to `build_tool_from_definition` at line 135, stores `iter_context` in `Command.context`.

Both confirmed: the context reference passed to `build_tool_from_definition` is what feeds the renderer (`TemplateRenderer::new()` in the builder). The renderer accepts any `HashMap<String, Value>`; no API change needed.

### workload pre-population at execute.rs:453 confirmed

`repos/server/src/handlers/execute.rs:453`:

```rust
context.insert(
    "workload".to_string(),
    serde_json::to_value(&context).unwrap_or_default(),
);
```

This happens BEFORE `build_command` / `build_iteration_command` is called in the initial-dispatch path. The `workload` key therefore already exists in `context` when the function is called. The `entry().or_insert_with()` guard in the implementation correctly preserves it.

### Caller audit — pre-populated `ctx` key

Grepped all callers of `build_command` and `build_iteration_command` across the codebase:

- `orchestrator.rs:281` — passes `context` which is the orchestrator's `WorkflowState.variables` map. No `ctx` key pre-populated.
- `orchestrator.rs:914` — passes `&current_ctx`. No `ctx` key pre-populated.
- `orchestrator.rs:943` — passes `&current_ctx`. No `ctx` key pre-populated.
- `execute.rs:506` — passes `&context` with `workload` pre-set (line 453). No `ctx` key.
- `execute.rs:531` — same context. No `ctx` key.
- `execute.rs:776` — passes `context` (the parameter from the outer function). No `ctx` key.
- `execute.rs:793` — same. No `ctx` key.

Conclusion: no caller currently pre-populates `ctx`. The `entry().or_insert_with()` guard for `ctx` is defensive future-proofing.

The `state.rs:735` reference to `"ctx"` is inside `apply_set_mutations` — it strips the `ctx.` scope prefix off mutation keys and writes the bare key to `variables`. It does NOT populate a `ctx` namespace dict in the context.

### Python contract re-confirmed

`repos/noetl/noetl/core/dsl/engine/executor/commands.py:915-916`:

```python
context["ctx"] = state.variables
context["workload"] = state.variables
```

These lines execute AFTER the iterator-namespace construction block (lines 905-913), which uses guards like `if "iter" in context`. The Rust implementation mirrors this order: for `build_iteration_command`, the `ctx`/`workload` shim is applied after `iter_context.insert(iterator.item_var, ...)` so the iterator value is visible through `{{ ctx.<item_var> }}`.

One deviation noted: Python unconditionally overwrites both keys (no idempotency guard). The Rust implementation uses `entry().or_insert_with()` instead, which is deliberately more conservative to preserve the existing `workload` YAML block already inserted by `execute.rs:453`. This is the correct behavior per the prompt's design contract.

---

## Phase B — implement + tests + build

### Diff summary

File touched: `repos/server/src/engine/commands.rs` only.

**`build_command`** (lines 99-133): Replaced single `build_tool_from_definition(... context ...)` call with:
1. `let mut render_ctx = context.clone()` — render-side clone.
2. `serde_json::to_value(context)` → `ctx_value`.
3. `render_ctx.entry("ctx").or_insert_with(|| ctx_value.clone())`.
4. `render_ctx.entry("workload").or_insert_with(|| ctx_value)`.
5. `build_tool_from_definition(&step.tool, &render_ctx)` — shimmed context.
6. `Command.context` still persists original `context.clone()`.

**`build_iteration_command`** (lines 151-168): Same shim pattern inserted after `iter_context.insert(iterator.item_var, ...)` / `_index` / `_total` insertions. `build_tool_from_definition` now receives `&render_ctx` (with shims). `Command.context` persists `iter_context` (without shims).

Net delta: +205 lines, -5 lines (mostly tests).

### Five new unit tests added

All in `mod tests` in `engine/commands.rs`:

1. `test_build_command_exposes_ctx_namespace` — flat `foo: 42` in context; URL template `{{ ctx.foo }}`; asserts renders to `42`; asserts persisted context has no `ctx` key (no event bloat).
2. `test_build_command_exposes_workload_namespace` — same but `{{ workload.foo }}` with no pre-existing `workload` key.
3. `test_build_command_preserves_existing_workload` — context has `workload: { session_token: "abc123" }` pre-set; URL template `{{ workload.session_token }}`; asserts resolves to `"abc123"` (shim did not clobber).
4. `test_build_command_preserves_flat_top_level_keys` — URL template mixes `{{ host }}` (flat) and `{{ ctx.path }}` (namespaced); both resolve correctly.
5. `test_build_iteration_command_ctx_includes_iterator_var` — loop item_var `"num"` = `42`; URL template `{{ ctx.num }}`; asserts resolves to `42`; asserts persisted context has no `ctx` key.

### Test count

- Pre-change (engine::commands module): 5 tests
- Post-change (engine::commands module): 10 tests (`10 passed / 0 failed`)
- Full lib suite: `594 passed / 0 failed`

### Release build outcome

```
Compiling noetl-server v2.60.0
Finished `release` profile [optimized] target(s) in 32.68s
```

Clean, no errors.

### Clippy outcome

`cargo clippy --lib --tests --release -- -D warnings`: zero errors or warnings in `engine/commands.rs`. Pre-existing clippy failures exist in other modules (`db/pool.rs`, `handlers/cross_region.rs`, `handlers/events.rs`, etc.) — none introduced by this change.

### Local commit SHA on `feat/ctx-workload-namespace-shim`

```
f554141  feat(engine): expose ctx + workload namespaces in dispatch render context
```

Branch is local only on `repos/server`. Not pushed (Phase C gated on `ship it`).

Note: The `repos/server` working tree had pre-existing uncommitted changes in 38 other files (format/lint fixes, various ongoing feature work). Only `src/engine/commands.rs` was staged and committed in this round.

---

## Phase C — open PR

Phase C blocked: awaiting `ship it`.

---

## Issues observed

1. **Pre-existing uncommitted changes in repos/server working tree**: 38 files were modified outside of this task (covering `cross_region.rs`, `pool.rs`, `replay.rs`, `secrets/` providers, etc.). These were present before the feature branch was created. Only `src/engine/commands.rs` was staged for the commit in this round. Claude should investigate whether these changes belong to an in-flight handoff or need to be cleaned up separately before pushing the feature branch.

2. **Pre-existing clippy failures**: The `--lib --tests --release -- -D warnings` run reports 14+ errors in modules unrelated to this change. These would block a CI clippy gate if one is configured. The feature branch commit itself is clean for `engine/commands.rs`.

3. **`serde_json::to_value(context)` on a `&HashMap<_, serde_json::Value>`**: Clippy passes without complaint; the conversion is well-defined (produces `Value::Object`). The `unwrap_or(Value::Null)` fallback is unreachable in practice because serializing a `HashMap<String, Value>` is infallible, but it satisfies the type system cleanly.

---

## Manual escalation needed

Claude follow-ups after `ship it` + PR merge:

1. **Investigate pre-existing working-tree changes** in `repos/server` before pushing the feature branch to avoid accidentally bundling unrelated in-flight work into the PR. Run `git diff HEAD -- <file>` per suspect file to confirm which task owns each change.
2. **Wait for release-please to tag** (likely v2.61.0 given the `feat:` prefix).
3. **Build noetl-server image and kind reload**: `noetl run automation/development/noetl.yaml --runtime local --set action=redeploy` from `repos/ops`.
4. **Re-run `test_args_passing.yaml`** — expect:
   - `ctx.test_var` resolves to `100` (the value set by the upstream arc's `set: { ctx.test_var: '{{ initial_value }}' }`).
   - `ctx.computed` resolves to `200`.
   - `use_vars` assertions pass.
   - Playbook reaches `playbook.completed`.
5. **Bump ai-meta pointer** to the new server SHA + close `noetl/ai-meta#74`.
