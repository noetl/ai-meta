---
thread: 2026-06-08-server-initial-iterator-fanout
round: 1
from: claude
to: codex
created: 2026-06-08T06:30:00Z
status: open
expects_result_at: round-01-result.md
wait_phrase: "ship it"
---

# noetl-server: iterator fan-out at the initial-dispatch path

> **Predecessor:** [noetl/ai-meta#73](https://github.com/noetl/ai-meta/issues/73)
> — the umbrella ai-task issue.  This handoff scopes the **first** of
> two distinct gaps in that issue's body: the **iterator-binding gap
> at initial dispatch**.  The second gap (`next.set:` value
> propagation across step transitions) is a separate, larger feature
> implementation — out of scope here, will land in a follow-up round.

You are mirroring an existing Phase D R3b iterator fan-out from the
orchestrator's mid-execution path into the orchestrator's
**initial-dispatch** path.  The infrastructure (`build_iteration_command`
+ `IteratorMetadata`) already exists in `repos/server/src/engine/commands.rs`;
only the call site at `repos/server/src/handlers/execute.rs::generate_initial_commands`
needs to learn about it.

## Background

- **Operating directory:** `/Volumes/X10/projects/noetl/ai-meta`.
- **Branch base:** `repos/server` is on `main` at the noetl-server
  v2.58.0 release commit (`7dab231`).  Do NOT bump the crate version
  — release-please owns versioning on a `feat:` commit prefix.
- **Files in scope:**
  - `repos/server/src/handlers/execute.rs:419-484` — the current
    single-command `generate_initial_commands` function.  Calls
    `build_command(...)` once, no iterator awareness.  **Primary
    edit site.**
  - `repos/server/src/engine/commands.rs:90-173` — existing
    `build_command()` (non-iterator) + `build_iteration_command()`
    (iterator-aware) helpers.  **Reference only — no edit needed.**
  - `repos/server/src/engine/orchestrator.rs:809-870` — the existing
    Phase D R3b fan-out site for mid-execution iterators.  Read it as
    the **shape to mirror**: it resolves the loop's `in` expression,
    iterates, creates one `IteratorMetadata` per iteration, calls
    `build_iteration_command()` per iteration, persists each command.
  - `repos/server/src/playbook/types.rs` — the `Step` + `LoopConfig`
    types; check what fields `Step::loop` exposes.

### The gap — concrete reproduction

`repos/e2e/fixtures/playbooks/loop_test.yaml` declares a `start`
step with a `loop:` block:

```yaml
- step: start
  loop:
    spec:
      mode: sequential
    in: "{{ numbers }}"
    iterator: "num"
  tool:
    kind: python
    input: { num: "{{ num }}", loop_index: "{{ loop_index }}" }
    code: |
      num = input_data.get('num')
      ...
      return {"number": num, ...}
```

Today the orchestrator dispatches `start` as a **single** command
with `args: {}` — the iterator binding for `num` is skipped because
`generate_initial_commands` calls `build_command()` (the
non-iterator path) instead of fanning out via
`build_iteration_command()`.

Evidence from the most recent kind exec (`322253869239242752`):

```sql
SELECT step_name, LEFT(context::text, 200) FROM noetl.command
WHERE execution_id = 322253869239242752 AND step_name = 'start';
```

Returns:

```
args: {}
tool_config: { args: {}, code: "num = input_data.get('num')\n..." }
```

The expected shape after the fix (mirroring the existing R3b path):
**three** commands for the `start` step (one per item in `numbers: [1,2,3,4,5]` — actually five), each with:

```
context: { num: <N>, _index: <I>, _total: 5, ... }
tool_config: { args: { num: <N>, _index: <I>, _total: 5 }, code: "..." }
iterator: { item_var: "num", index: <I>, total: 5, ... }
```

## Phases

### Phase A — read-only survey (unattended)

1. Read `repos/server/src/handlers/execute.rs:419-484` end-to-end.
   Identify the exact line that calls `build_command(...)`.
2. Read the existing Phase D R3b fan-out at
   `repos/server/src/engine/orchestrator.rs:779-870` end-to-end.
   Identify:
   - How it resolves the loop's `in` expression (the renderer
     call).
   - How it constructs each `IteratorMetadata` instance.
   - How it persists each iteration's command.
3. Read `repos/server/src/playbook/types.rs` for `Step` + `LoopConfig`
   shapes.  Confirm `step.loop` is `Option<LoopConfig>` and that
   `LoopConfig::in_expression` (or whatever the field is named)
   carries the raw template string.
4. Read `repos/server/src/engine/commands.rs:116-173`
   (`build_iteration_command`) so the signature + the
   `IteratorMetadata` shape are clear.
5. Capture all line numbers + signatures in your final report.

### Phase B — implement + tests + clippy + release build (unattended)

> Run unattended.  No remote writes.  Commit locally on a feature branch.

6. Create branch `feat/initial-dispatch-iterator-fanout` on
   `repos/server` (off current `main`).
7. Edit `repos/server/src/handlers/execute.rs::generate_initial_commands`:
   - After resolving the `start_step` + building `context`, check
     `start_step.loop`.
   - If `start_step.loop` is `None`: keep the existing single-command
     path verbatim (build via `build_command()`, persist via
     `persist_engine_command`, return `Ok(1)`).
   - If `start_step.loop` is `Some(loop_cfg)`: resolve the
     `in:` template expression against `context` to a JSON array;
     iterate the array; for each `(index, item)` build an
     `IteratorMetadata` (filling `iterator_step`, `item_var`,
     `item`, `index`, `total`); call
     `command_builder.build_iteration_command(...)`; persist each
     command via `persist_engine_command`.  Return
     `Ok(total_count)`.
   - Mirror the resolution + iteration shape from the R3b
     fan-out in `orchestrator.rs` — same renderer, same array
     handling, same per-iteration metadata.
   - If the `in:` expression resolves to anything that's NOT a
     JSON array (null, scalar, object), return an `AppError::Validation`
     with a message like
     `"start step loop.in must resolve to a JSON array, got: <type>"`.
8. Add unit tests:
   - `test_generate_initial_commands_fans_out_when_start_has_loop`
     — start step with `loop: { in: '{{ items }}', iterator: 'item' }`
     and `workload.items: [1, 2, 3]` produces 3 commands, each
     carrying iterator metadata with `item_var: "item"`,
     `index: 0|1|2`, `total: 3`.
   - `test_generate_initial_commands_single_command_when_no_loop`
     — back-compat: start step WITHOUT loop produces exactly 1
     command with no iterator metadata.
   - `test_generate_initial_commands_rejects_non_array_loop_in`
     — `loop.in` resolving to a scalar / null returns
     `AppError::Validation` with the documented message.
9. `cd repos/server && cargo fmt && cargo build --release` — must
   be clean.
10. `cargo test --lib` — must pass entirely; record `<total>
    passed / 0 failed` count.
11. `cargo clippy --lib --tests --release -- -D warnings` —
    zero new errors in `handlers/execute.rs`.  Pre-existing
    debt from [noetl/server#161](https://github.com/noetl/server/issues/161)
    in other files is out-of-scope.
12. Commit locally with a `feat:` prefix message that cites
    `Refs noetl/ai-meta#73` in the body (NOT `Closes` —
    #73 has a second gap, `next.set:` propagation, that this
    PR doesn't address).  Stage all changes under `repos/server`
    only.  Do NOT push.

### Phase C — push branch + open PR (gated on `ship it`)

> ***Run only after explicit human go-ahead. Wait phrase: `ship it`.***

13. `git push -u origin feat/initial-dispatch-iterator-fanout`
    on `repos/server`.
14. Open the PR via `gh pr create` with:
    - Title: `feat(engine): fan out start step when it has a loop block`
    - Body citing `Refs noetl/ai-meta#73` in the footer.
    - Test plan section listing the three new unit tests + the
      kind re-val expectations.
15. Comment on noetl/ai-meta#73 with the PR URL.
16. **STOP.**  Do not roll the kind deployment, do not bump
    pointers in ai-meta.  Claude owns that follow-up once the PR
    merges.

## FINAL REPORT

Always emit this, even on early STOP.  Write it as the body of
`expects_result_at` with frontmatter:

```yaml
---
thread: 2026-06-08-server-initial-iterator-fanout
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
- Line numbers + signatures.
- R3b fan-out shape (renderer, IteratorMetadata construction).
- Step + LoopConfig type fields.

## Phase B — implement + tests + build
- Diff summary (lines added/removed, files touched).
- Test count: `<N> passed / 0 failed` (was `<M>` pre-change).
- Release build outcome.
- Clippy outcome.
- Local commit SHA on `feat/initial-dispatch-iterator-fanout`.

## Phase C — open PR
- Either: PR URL + comment URL.  OR: `Phase C blocked: awaiting ship it`.

## Issues observed
- Anything surprising.  Real error strings if anything failed.

## Manual escalation needed
- Claude (dispatcher) follow-ups after PR merges:
  - Wait for release-please to tag the new version.
  - Build noetl-server image, kind reload, re-run loop_test.yaml.
  - Verify orchestrator dispatches 5 iterator-bound start commands.
  - Bump ai-meta pointer + comment on noetl/ai-meta#73 with the
    progress on gap 1; gap 2 (`next.set:` propagation) still
    pending in a future round.
```

## Hard rules for this thread

- Never push to `origin/main` on any repo.
- Never force-push.
- Never merge PRs yourself.
- Respect `AGENTS.md` and the rules under `agents/rules/`.
- Do NOT bump the noetl-server version in `Cargo.toml` by hand —
  release-please owns versioning; a `feat:` commit prefix triggers
  the MINOR bump.
- Do NOT touch Python code.  Python reference (if you need it for
  parity) lives in `repos/noetl/noetl/server/api/core/events.py`
  — read-only.
- This round scopes ONLY the iterator-binding gap.  The
  `next.set:` propagation gap is explicitly out-of-scope (different
  code path; will land separately).
- Do not store secrets in any file under ai-meta (public repo).
- If a step's preconditions aren't met, stop and report — don't
  improvise around blockers.
