---
thread: 2026-05-22-phase6-stage-planner-wiring
round: 1
from: claude
to: claude
created: 2026-05-22T21:02:44Z
status: open
expects_result_at: round-01-result.md
---

# Phase 6: extend stage-planner wiring beyond command metadata

> **Predecessor:** Phase 1 completed in
> `handoffs/archive/2026-05-22-phase1-frame-projections/` (noetl v2.90.0).

After surveying noetl `main` (sha `68eea845`), the v2 spec audit
table's "Phase 6 — not started" is **out of date**. The planner is
already wired into the engine — `transitions.py` line 822 has
`_annotate_fanout_reduce_commands()` that calls
`build_fanout_reduce_plan(state.playbook)` and decorates fan-out
commands with a rich `fanout_reduce` metadata block (planner_version,
fanout_step, fanout_targets, target_step, target_index, reduce_steps).

The remaining Phase 6 delta is **smaller and more focused** than the
audit table suggests. This round closes three concrete gaps without
changing runtime behavior.

## Background

### Existing surface (confirmed)

- [`noetl/core/dsl/engine/planner.py`](https://github.com/noetl/noetl/blob/main/noetl/core/dsl/engine/planner.py)
  — `build_fanout_reduce_plan(playbook) -> FanoutReducePlan`.
  Side-effect-free, deterministic, fully tested elsewhere.
- [`noetl/core/dsl/engine/executor/transitions.py`](https://github.com/noetl/noetl/blob/main/noetl/core/dsl/engine/executor/transitions.py)
  line 822 — `_annotate_fanout_reduce_commands` already wires the
  planner into command emission for **inclusive-mode** fan-out
  arcs. Commands targeting fan-out children carry
  `metadata["fanout_reduce"]` with the static plan slice.
- Wiki: [DSL Planner](https://github.com/noetl/noetl/wiki/dsl_planner).
- `FanoutReducePlan.reduces` is computed correctly today but **not
  used by the engine**.

### Three concrete gaps

1. **Plan recomputed per call.** Every time a fan-out arc fires,
   `build_fanout_reduce_plan(state.playbook)` runs from scratch. A
   playbook with many fan-outs (or a high-throughput PFT-style
   workload) pays the cost on every transition. The plan is a pure
   function of the playbook — should be computed **once** and cached
   on `ExecutionState`.

2. **Reducer-bound commands aren't annotated.** Today only fan-out
   commands get `fanout_reduce` metadata. When a step terminates
   and its `next.arcs` target a reducer (a step with ≥2 upstream
   per the plan), the resulting command has no static knowledge
   that it's hitting a reduce boundary. Downstream tooling
   (replay, dashboards, future scheduler integration) can't ask
   "is this command landing at a planned reducer?" without
   re-running the planner.

3. **No register-time validation.** The planner exposes structural
   information that a register-time validator could lint:
   - Fan-out boundaries whose `reduce_steps` is empty (the
     fan-out has no downstream join — usually intentional but
     worth flagging).
   - Reducers with `upstream_steps` length < 2 (orphan reducers
     — likely a typo in the YAML).
   - Reducers referenced as `next` targets but missing from the
     workflow (already partially caught by Pydantic but not
     planner-aware).

The minimal viable Phase 6 closes these three gaps without changing
runtime behavior. **Reducer-wait semantics** (defer scheduling until
all upstream terminate) is intentionally deferred — that's a
behavior change with replay implications and deserves its own round.

## Phases

### Phase A — design + drift check (no remote writes)

1. Re-read this prompt's "Existing surface" section against
   `noetl/core/dsl/engine/{planner.py,executor/transitions.py}`
   on `origin/main`. Flag any drift.
2. Locate `ExecutionState` (likely in
   `noetl/core/dsl/engine/executor/state.py`). Confirm it has a
   `playbook` field and is constructed per-execution at engine
   start. Note where in its lifecycle the plan should be cached
   (constructor, lazy property, or explicit hook).
3. Decide the canonical access path: `state.fanout_reduce_plan`
   as a lazy `@cached_property` on `ExecutionState` is the
   expected shape, but the executor may use plain dict-shaped
   state — adopt whatever idiom the file already uses.
4. Decide the validation surface: either a new helper in
   `engine/planner.py` (e.g., `validate_fanout_reduce_plan(playbook)
   -> list[str]`) returning warning strings, called from
   `parser/validation.py`, or an inline extension of the existing
   `_validate_canonical_v10`. Recommendation: a planner-side
   helper so the validation logic stays near the plan it
   inspects.

### Phase B — implementation

5. **Cache the plan on `ExecutionState`** —
   `state.fanout_reduce_plan` (lazy or eager — match the file's
   style). Update the call site in
   `_annotate_fanout_reduce_commands` to use the cached
   accessor instead of `build_fanout_reduce_plan(state.playbook)`.

6. **Annotate reducer-bound commands.** Extend
   `_annotate_fanout_reduce_commands` (or add a sibling
   `_annotate_reducer_commands`) that, for every issued command,
   checks if its `target_step` is in
   `plan.reduces`. If yes, attach a
   `metadata["planner_reducer"]` block with:
   ```python
   {
       "planner_version": 1,
       "reducer_step": <target step>,
       "upstream_steps": [<list from the matching PlannedReduce>],
   }
   ```
   The `source_step` is the step terminating that emits the
   command. Reducer annotation can fire **regardless of
   next.spec.mode** — it's static plan information, not gated on
   exclusive vs inclusive.

7. **Register-time validation.** Add
   `validate_fanout_reduce_plan(playbook) -> list[str]` to
   `engine/planner.py`. Returns a list of warning strings (not
   errors — these are advisory, like the docstring already
   suggests for "fan-out without reducer"). Wire it into
   the parser's validation pipeline:
   - `parser/core.py` → after `_validate_canonical_v10` succeeds
     and the `Playbook` model is constructed, call the validator.
   - On non-empty warnings, log them via `noetl.core.logger`
     at WARNING level prefixed `[DSL.PLANNER]`.
   - Do **not** raise. Validation is advisory.

### Phase C — tests

8. Extend `tests/core/dsl/test_engine_planner.py` (create if
   missing) covering:
   - Cached access — patching `build_fanout_reduce_plan` and
     ensuring it's called exactly once per `ExecutionState`
     lifecycle even across multiple fan-out transitions.
   - Reducer-bound command annotation — synthetic playbook with
     a fan-out boundary and a downstream reducer; assert the
     reducer-bound command has `metadata["planner_reducer"]`
     with the expected `upstream_steps` tuple.
   - `validate_fanout_reduce_plan` returns warnings for:
     - Fan-out with empty `reduce_steps`.
     - Reducer with `len(upstream_steps) < 2` (synthesize via
       direct construction since the planner only produces these
       for valid inputs).
     - Empty plan (`is_empty() == True`) returns `[]`.

9. Run the focused test file plus
   `tests/core/test_replay_state_projector.py` (regression
   guard for Phase 1) and any existing
   `tests/core/dsl/engine/*` files. All green.

### Phase D — wiki update

10. Update [`noetl/core/dsl/engine/dsl_planner.md`](https://github.com/noetl/noetl/wiki/dsl_planner)
    in `repos/noetl-wiki/`:
    - "Where the plan is used" section: move "runtime stage
      opener" from "Planned" to "Today", and add a new "Planned"
      bullet for reducer-wait semantics.
    - Add a new subsection "Engine integration" covering:
      - `state.fanout_reduce_plan` cached accessor.
      - `metadata["fanout_reduce"]` shape on fan-out commands.
      - `metadata["planner_reducer"]` shape on reducer-bound
        commands.
      - `validate_fanout_reduce_plan(playbook)` helper +
        register-time invocation.
11. Push the wiki commit to `origin master`.

### Phase E — verify locally

12. Run the focused unit tests via
    `pytest tests/core/dsl/test_engine_planner.py tests/core/test_replay_state_projector.py -q`.
13. (Optional, time-permitting) Bring up local kind via
    `repos/ops/automation/development/noetl.yaml --set action=redeploy --set noetl_repo_dir=../noetl`,
    run a small playbook with a fan-out boundary (any GLUT
    distributed playbook works), then SQL:
    ```sql
    SELECT command_id, step_name,
           meta->>'fanout_reduce' AS fanout_reduce,
           meta->>'planner_reducer' AS planner_reducer
    FROM noetl.command
    WHERE execution_id = <recent>
    ORDER BY command_id
    LIMIT 50;
    ```
    Confirm both metadata families populate per the design.

### Phase F — open PR and merge

> ***Run only after explicit human go-ahead. Wait phrase: `merge phase 6`.***

14. Push the branch `kadyapam/phase6-stage-planner-wiring`, open
    a noetl PR titled `feat(engine): cache fanout/reduce plan and
    annotate reducer commands`. PR body references this handoff
    and the wiki page update.
15. Wait for CI / human review.
16. Merge with `--admin --merge --delete-branch` once approved.
17. Bump pointers in ai-meta: one chore(sync) commit for noetl,
    one for noetl-wiki. Push.

## FINAL REPORT

Always emit `round-01-result.md` even on early STOP. Frontmatter:

```yaml
---
thread: 2026-05-22-phase6-stage-planner-wiring
round: 1
from: claude
to: claude
created: <ISO8601 UTC>
in_reply_to: round-01-prompt.md
status: complete | partial | blocked
---
```

Body sections — one H2 per Phase A–F plus `## Issues observed` and
`## Manual escalation needed`.

## Hard rules

- Never push to `origin/main` on any repo unless this prompt says
  so. Phase F is the only step that pushes, gated by `merge phase 6`.
- Never force-push.
- Never merge PRs yourself before the gate phrase.
- Respect `AGENTS.md` and `agents/rules/wiki-maintenance.md` —
  the Phase D wiki edit ships paired with the code change.
- Do not store secrets in any file under ai-meta.
- If a step's preconditions aren't met, stop and write the report
  with `status: blocked` — don't improvise around blockers.
- **Behavior change is out of scope.** Reducer-wait semantics
  (defer scheduling until all upstream complete) belongs to a
  future round. This round only adds static plan metadata and
  caching.
