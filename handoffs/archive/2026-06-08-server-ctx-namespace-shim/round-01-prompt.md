---
thread: 2026-06-08-server-ctx-namespace-shim
round: 1
from: claude
to: codex
created: 2026-06-08T07:50:00Z
status: open
expects_result_at: round-01-result.md
wait_phrase: "ship it"
---

# noetl-server: expose `ctx` (and `workload`) namespace in dispatch render context

> **Predecessor:** [noetl/ai-meta#73](https://github.com/noetl/ai-meta/issues/73)
> closed via PR #163 (v2.60.0) — arc-level `set:` apply works
> (bare keys land in dispatch context).  Kind re-val on
> `test_args_passing.yaml` revealed the downstream Jinja
> templates `{{ ctx.test_var }}` still resolve to null because
> the render context doesn't expose a `ctx` namespace.  This
> round closes [noetl/ai-meta#74](https://github.com/noetl/ai-meta/issues/74).

You are porting a small piece of Python's render-context
construction into Rust's `CommandBuilder`.  The Python contract is
crisp (one line in `commands.py:915`): `context["ctx"] =
state.variables`.  Mirror it in Rust.

## Background

- **Operating directory:** `/Volumes/X10/projects/noetl/ai-meta`.
- **Branch base:** repos/server is on `main` at the noetl-server
  v2.60.0 release commit (`084cad4`).
- **Files in scope:**
  - `repos/server/src/engine/commands.rs:88-114` (`build_command`)
    + `:116-173` (`build_iteration_command`).  **Primary edit
    sites.**
  - `repos/server/src/template/jinja.rs` — `TemplateRenderer`
    API.  Read-only — the renderer accepts any
    `HashMap<String, Value>` as context; no API change needed.
- **Python reference (read-only, parity target):**
  - `repos/noetl/noetl/core/dsl/engine/executor/commands.py:915-916`
    — `context["ctx"] = state.variables` + `context["workload"]
    = state.variables`.  The lines around it show iterator-side
    bindings too, but for THIS round the MVP is just `ctx` +
    `workload`.  `iter` and `step` namespaces are bigger and
    out-of-scope here.

### The gap — concrete reproduction

From kind exec `322277934767280128` (`test_args_passing.yaml`
on v2.60.0):

- Upstream arc has `set: { ctx.test_var: '{{ initial_value }}',
  ctx.computed: 200 }`.
- `apply_set_mutations` (from #163) correctly strips `ctx.` and
  writes `test_var: 100` + `computed: 200` to the dispatch
  context.
- Downstream step's `input: { test_var: '{{ ctx.test_var }}',
  computed: '{{ ctx.computed }}' }`.
- Worker render result: `tool_config.args: { test_var: null,
  computed: null }`.

The Jinja path `ctx.test_var` requires `ctx` to be a key in the
render context AND for that key's value to be a dict containing
`test_var`.  The current Rust context has a flat `test_var`
top-level key but no `ctx` key.

Python's contract:

```python
context["ctx"] = state.variables       # the flat dict of bare keys
context["workload"] = state.variables  # also aliased
```

So `{{ ctx.test_var }}` resolves via `state.variables["test_var"]`
through the `ctx` shim, AND `{{ test_var }}` ALSO resolves
through the flat top-level binding.

## Design contract for this round

Wrap the render context in `CommandBuilder::build_command` and
`build_iteration_command` BEFORE handing it to
`build_tool_from_definition` (which is where the renderer is
invoked).  Add **two** new keys to the context:

- `ctx` → `serde_json::Value::Object` view of the existing
  context (every key/value of the input context turned into a
  JSON object).  Equivalent to Python's
  `context["ctx"] = state.variables`.
- `workload` → same value (alias).  Equivalent to Python's
  `context["workload"] = state.variables`.

Both namespaces point to the same underlying data — the dispatch
context as built by the caller (orchestrator), which already
contains the post-`apply_set_mutations` bare keys.

The flat top-level keys MUST remain.  Existing fixtures that
reference `{{ workload.session_token }}` (where `workload` is
the YAML workload block, already populated) need to keep
working — but inspect whether the current
`generate_initial_commands` already inserts `workload` into the
context (it does, at `execute.rs:453`).  Decision: when the
incoming context ALREADY has `workload`, prefer the existing
binding (it's the YAML's workload block as a structured object)
over overwriting with the flat dict.  Same for `ctx` — if
`ctx` already in context, leave it alone.

Concretely, the wrapping logic is:

```rust
let mut render_ctx = context.clone();
// Use entry().or_insert_with(...) so we don't clobber
// existing bindings.  ctx + workload point to a view of the
// flat dispatch context (the post-apply_set_mutations state).
let ctx_value = serde_json::to_value(&context).unwrap_or(serde_json::Value::Null);
render_ctx.entry("ctx".to_string()).or_insert_with(|| ctx_value.clone());
render_ctx.entry("workload".to_string()).or_insert_with(|| ctx_value);
// Then pass &render_ctx (not &context) to build_tool_from_definition.
```

### Why entry().or_insert_with() and not blind insert

- `workload` is already populated by `generate_initial_commands`
  with the structured YAML workload block (`execute.rs:453`).
  Overwriting it would break `{{ workload.session_token }}` style
  references.
- `ctx` is currently never set, but defensive-coding for future
  call sites that may pre-populate it.

This is the same idempotency pattern Python uses (the assignments
at `commands.py:915-916` happen AFTER the iterator namespace
construction at lines 905-913 which uses `if "iter" in context`
guards).

## Phases

### Phase A — read-only survey (unattended)

1. Read `repos/server/src/engine/commands.rs:88-173` end-to-end.
   Confirm both `build_command` and `build_iteration_command`
   call `build_tool_from_definition(... context ...)` and that
   `context` is what the renderer ultimately uses.
2. Read `repos/server/src/handlers/execute.rs:430-470` to
   confirm `workload` is pre-populated by `generate_initial_commands`
   in the initial-dispatch path.
3. Grep for all current callers of `build_command` and
   `build_iteration_command` to confirm they all pass a context
   that doesn't already have `ctx`.  If any does, note it.
4. Read Python's reference lines around
   `commands.py:915-916` to confirm the exact contract.
5. Capture findings in your final report.

### Phase B — implement + tests + clippy + release build (unattended)

> Run unattended.  No remote writes.  Commit locally on a feature branch.

6. Create branch `feat/ctx-workload-namespace-shim` on
   `repos/server` (off current `main`).
7. Edit `repos/server/src/engine/commands.rs`:
   - In `build_command`: clone the incoming `context` into
     `render_ctx`, use `entry(...).or_insert_with(...)` to add
     `ctx` + `workload` namespace keys pointing to a
     `serde_json::Value::Object` view of the original context.
     Pass `&render_ctx` to `build_tool_from_definition`.  The
     persisted `Command.context` should still be the
     **original** flat context (not the shimmed render_ctx) —
     the wrapping is only for the render path, not for the
     event-log shape (avoids context bloat in event payloads).
   - Same shape in `build_iteration_command`: shim AFTER the
     iterator-var insertions (`iter_context.insert(iterator.item_var, ...)`)
     so the iterator value is also present in the `ctx`
     namespace view.  Persist `iter_context` (without the
     namespace shim) on the command.
8. Add unit tests:
   - `test_build_command_exposes_ctx_namespace` — input context
     has flat `foo: 42`; render template `{{ ctx.foo }}`;
     resolve to `42`.
   - `test_build_command_exposes_workload_namespace` — same
     shape but `{{ workload.foo }}`.
   - `test_build_command_preserves_existing_workload` — input
     context already has `workload: { session_token: 'abc' }`
     (the structured YAML block).  Render
     `{{ workload.session_token }}` and confirm it resolves to
     `'abc'` (the existing structured value), NOT clobbered by
     a flat-dict shim.
   - `test_build_command_preserves_flat_top_level_keys` —
     `{{ foo }}` still resolves alongside `{{ ctx.foo }}`.
   - `test_build_iteration_command_ctx_includes_iterator_var`
     — for a loop iteration with `iterator.item_var = "num"`,
     iterator.item = `42`, the render `{{ ctx.num }}` resolves to
     `42`.
9. `cd repos/server && cargo fmt && cargo build --release` —
   must be clean.
10. `cargo test --lib` — must pass entirely.  Record `<total>
    passed / 0 failed` count.
11. `cargo clippy --lib --tests --release -- -D warnings` —
    zero new errors in `engine/commands.rs`.
12. Commit locally with a `feat:` prefix message citing
    `Closes noetl/ai-meta#74` in the body.  Stage all changes
    under `repos/server` only.  Do NOT push.

### Phase C — push branch + open PR (gated on `ship it`)

> ***Run only after explicit human go-ahead. Wait phrase: `ship it`.***

13. `git push -u origin feat/ctx-workload-namespace-shim` on
    `repos/server`.
14. Open the PR via `gh pr create` with:
    - Title: `feat(engine): expose ctx + workload namespaces in dispatch render context`
    - Body citing `Closes noetl/ai-meta#74` in the footer.
    - Test plan section listing the 5 new unit tests + the kind
      re-val expectations (`test_args_passing.yaml` reaches
      `playbook.completed` with `use_vars` assertions passing).
15. Comment on noetl/ai-meta#74 with the PR URL.
16. **STOP.**  Do not roll the kind deployment.  Claude owns the
    follow-up.

## FINAL REPORT

Always emit this, even on early STOP.  Write it as the body of
`expects_result_at` with frontmatter:

```yaml
---
thread: 2026-06-08-server-ctx-namespace-shim
round: 1
from: codex
to: claude
created: <ISO8601 UTC>
in_reply_to: round-01-prompt.md
status: complete | partial | blocked
---
```

Then the report markdown:

```markdown
## Phase A — read-only survey
- build_command + build_iteration_command structure confirmed.
- workload pre-population at execute.rs:453 confirmed.
- Caller audit (any pre-populated `ctx` key in current context?).
- Python contract re-confirmed (any deviation noted).

## Phase B — implement + tests + build
- Diff summary (lines added/removed, files touched).
- Test count: `<N> passed / 0 failed` (was `<M>` pre-change).
- Release build outcome.
- Clippy outcome.
- Local commit SHA on `feat/ctx-workload-namespace-shim`.

## Phase C — open PR
- Either: PR URL + comment URL.  OR: `Phase C blocked: awaiting ship it`.

## Issues observed
- Anything surprising.

## Manual escalation needed
- Claude follow-ups after PR merges:
  - Wait for release-please to tag (likely v2.61.0).
  - Build noetl-server image, kind reload.
  - Re-run test_args_passing.yaml — expect use_vars assertions to pass + playbook fully green.
  - Bump ai-meta pointer + close noetl/ai-meta#74.
```

## Hard rules for this thread

- Never push to `origin/main` on any repo.
- Never force-push.
- Never merge PRs yourself.
- Respect `AGENTS.md` and the rules under `agents/rules/`.
- Do NOT bump the noetl-server version in `Cargo.toml` — release-please owns versioning; `feat:` triggers the MINOR bump.
- Do NOT touch Python code.  Reference-only.
- Do not store secrets in any file (public repo).
- If a step's preconditions aren't met, stop and report — don't improvise around blockers.
