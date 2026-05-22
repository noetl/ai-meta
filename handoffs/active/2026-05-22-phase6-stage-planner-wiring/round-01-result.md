---
thread: 2026-05-22-phase6-stage-planner-wiring
round: 1
from: claude
to: claude
created: 2026-05-22T21:13:13Z
in_reply_to: round-01-prompt.md
status: partial
---

# Phase 6 result — stage-planner wiring (additive scope)

Phases A–D executed in this session. Phase E partial (focused unit
tests run; local kind verify skipped). Phase F **open as PR #586**,
merge gated on wait phrase `merge phase 6`.

## Phase A — design + drift check

- Source matches the prompt. The audit table's "Phase 6 not started"
  was already stale: `transitions.py:822-856` had
  `_annotate_fanout_reduce_commands` calling
  `build_fanout_reduce_plan(state.playbook)` on every transition.
- Confirmed `ExecutionState` is a plain class (not `dataclass`, not
  `@cached_property`-based) at
  `noetl/core/dsl/engine/executor/state.py:5`. Picked a sentinel
  `_fanout_reduce_plan: Optional[FanoutReducePlan] = None` field +
  lazy `@property` — matches the rest of the file's idioms.
- Picked `validate_fanout_reduce_plan(playbook) -> list[str]` as a
  helper in `planner.py` rather than inlining in `parser/validation.py`.
  Reason: the validator is plan-aware and naturally lives next to
  `build_fanout_reduce_plan`. The parser just calls it.

## Phase B — implementation

Branch: `kadyapam/phase6-stage-planner-wiring` in `repos/noetl`.
Commit: `47349285 feat(engine): cache fanout/reduce plan and annotate reducer commands`.

Files (+333 / −4):

- `noetl/core/dsl/engine/planner.py`
  - Added `validate_fanout_reduce_plan(playbook) -> list[str]`.
    Returns advisory warnings — never raises.
  - Warning codes: `[fanout_no_reducer]` (inclusive fan-out with no
    reachable reducer) and `[reducer_orphan]` (reducer with <2
    upstream — defensive guard for hand-built plans).

- `noetl/core/dsl/engine/executor/state.py`
  - Imported `FanoutReducePlan, build_fanout_reduce_plan`.
  - Added `_fanout_reduce_plan: Optional[FanoutReducePlan] = None`
    field in `__init__`.
  - Added `fanout_reduce_plan` lazy `@property`.

- `noetl/core/dsl/engine/executor/transitions.py`
  - Replaced direct `build_fanout_reduce_plan(state.playbook)` in
    `_annotate_fanout_reduce_commands` with `state.fanout_reduce_plan`.
  - Removed the now-unused direct import of `build_fanout_reduce_plan`.
  - Added new `_annotate_reducer_commands` method that runs after
    every transition (not gated on `next.spec.mode`). Attaches
    `metadata["planner_reducer"]` with
    `{planner_version: 1, reducer_step, upstream_steps, source_step}`
    for any command whose `target_step` is a planned reducer.

- `noetl/core/dsl/engine/parser/core.py`
  - Imported `validate_fanout_reduce_plan` and set up a
    `_planner_logger` on the `noetl.core.dsl.engine.planner` logger
    name.
  - After Pydantic construction in `DSLParser.parse`, calls
    `_emit_planner_warnings(playbook)` which logs warnings at
    WARNING level prefixed `[DSL.PLANNER]`. Wrapped in try/except
    so a planner crash never blocks parsing.

## Phase C — tests

Added 6 tests to `tests/unit/dsl/engine/test_fanout_reduce_planner.py`:

- `test_validate_fanout_reduce_plan_returns_empty_for_clean_playbook`
  — well-formed playbook returns `[]`.
- `test_validate_fanout_reduce_plan_warns_when_fanout_has_no_reducer`
  — inclusive fan-out without a join → 1 warning starting
  `[fanout_no_reducer]`.
- `test_validate_fanout_reduce_plan_warns_for_orphan_reducer`
  — synthesizes a `PlannedReduce(upstream_steps=("solo",))` via
  `unittest.mock.patch` of `build_fanout_reduce_plan`, asserts
  `[reducer_orphan]`.
- `test_validate_fanout_reduce_plan_empty_plan_returns_no_warnings`
  — empty plan short-circuits to `[]`.
- `test_execution_state_caches_fanout_reduce_plan` — spies on
  `build_fanout_reduce_plan` via `patch.object(state_module,
  "build_fanout_reduce_plan", wraps=...)` and asserts the planner
  ran exactly **once** across 3 property accesses, and that the
  returned objects are identical.
- `test_execution_state_fanout_reduce_plan_for_linear_playbook`
  — empty plan for a single-step playbook; cached identity check.

Test runs:

```
pytest tests/unit/dsl/engine/test_fanout_reduce_planner.py
       tests/core/test_replay_state_projector.py
       tests/core/test_projector_metrics.py -q
→ 122 passed, 105 warnings in 3.34s
```

Phase 1 regression guard (frame projections) is in the run set and
green.

## Phase D — wiki update

Wiki: `repos/noetl-wiki/` commit `1fdb8c6 wiki(dsl_planner): document Phase 6 engine integration`. Pushed to `origin master`.

Page updated: [`noetl/core/dsl/engine/dsl_planner`](https://github.com/noetl/noetl/wiki/dsl_planner):

- "Where the plan is used" — moved validation from Today's "CLI
  lint tools" implication to register-time runtime usage. Added a
  new Planned bullet for reducer-wait semantics.
- New "Engine integration" section covering the cached accessor,
  the two command-metadata annotation passes
  (`fanout_reduce` + `planner_reducer`), and the
  `validate_fanout_reduce_plan` helper invocation.

Per `agents/rules/wiki-maintenance.md` rule #1: wiki shipped in
the same change set as the code.

## Phase E — verify locally

**Partial.** Focused unit tests run successfully (Phase C). Local
kind redeploy + SQL inspection of `noetl.command.meta` was not
exercised in this session — same reason as Phase 1, the
infrastructure verify is best done by an operator with the kind
cluster up.

The SQL the prompt suggests:

```sql
SELECT command_id, step_name,
       meta->>'fanout_reduce' AS fanout_reduce,
       meta->>'planner_reducer' AS planner_reducer
FROM noetl.command
WHERE execution_id = <recent>
ORDER BY command_id
LIMIT 50;
```

After redeploying with this PR's branch and running any GLUT
distributed playbook with a fan-out boundary, `fanout_reduce`
should appear on the fan-out children (unchanged from prior
behavior) and `planner_reducer` should appear on the
join-targeting command (new behavior).

## Phase F — open PR and merge

**PR open, merge gated on wait phrase `merge phase 6`.**

- PR: [noetl#586 — feat(engine): cache fanout/reduce plan and annotate reducer commands](https://github.com/noetl/noetl/pull/586)
- Branch: `kadyapam/phase6-stage-planner-wiring` pushed to origin.
- PR body references this handoff thread and the wiki commit.
- Coordinating commits ready after merge:
  - `chore(sync): bump noetl to <merge sha>`
  - `chore(sync): bump noetl-wiki to 1fdb8c6`

## Issues observed

- The original `_annotate_fanout_reduce_commands` used a direct
  `build_fanout_reduce_plan` import. After switching to the cached
  accessor, the import was unused. Replaced the line with a
  comment so future-readers see why it was removed (and where to
  find the new path) rather than diff-noise.
- The reducer-annotation runs on **every** transition, not only
  on inclusive-mode ones. Considered whether this could mis-fire
  on exclusive-mode arcs that happen to target a planner-reducer
  step — but the planner only flags reducers when ≥2 upstream
  exist, so by definition such a command from an exclusive arc
  belongs to one of those upstream contributors. The static
  metadata is correct either way.

## Manual escalation needed

- **Wait phrase**: human says `merge phase 6` to unlock Phase F's
  merge step.
- After merge, the bump procedure mirrors Phase 1:
  ```bash
  cd repos/noetl && git checkout main && git pull origin main
  cd ../.. && git add repos/noetl repos/noetl-wiki
  git commit -m "chore(sync): bump noetl + noetl-wiki for Phase 6 stage-planner wiring"
  git push origin main
  ```
- Optional: run Phase E locally before saying `merge phase 6` to
  confirm the `meta->>'planner_reducer'` rows materialize.
