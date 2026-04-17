# Bug: PFT Task Sequence Leaks Raw Jinja into Postgres After Synthetic Loop Restore

## Summary
- Fresh validation run `606932901669634625` executed on `local/noetl:arm64-d2ad24d9` and passed the prior distributed loop stall boundaries.
- The run later failed inside `fetch_assessments:task_sequence` with raw Jinja reaching Postgres SQL:
  - `command_0: syntax error at or near "{"`
  - `LINE 4:     {{ iter.patient.patient_id }},`
- This is a new failure mode after fix #4: loop completion now advances, but at least one resumed task-sequence iteration loses the real `iter.patient` payload needed to render the `save_page` SQL.

## Scope (Repos)
- repos/noetl: distributed engine + worker runtime behavior for loop restoration, task-sequence rendering, and Postgres execution
- repos/noetl: fixture playbook used for validation at `tests/fixtures/playbooks/pft_flow_test/test_pft_flow.yaml`
- repos/ops: no code change in this incident; local validation environment only

## PRs / Links
- repos/noetl: none yet
- Related validation execution: `606932901669634625`

## Resulting SHAs / Tags
- repos/noetl: `d2ad24d9`
- ai-meta: `240c772`
- Runtime image: `local/noetl:arm64-d2ad24d9`

## Observed Failure

Fresh run status:

- Execution: `606932901669634625`
- Path: `tests/fixtures/playbooks/pft_flow_test/test_pft_flow`
- Runtime: distributed, local kind cluster

Failure signature from execution record:

```text
command_0: syntax error at or near "{"
LINE 4:     {{ iter.patient.patient_id }},
            ^
```

Server-side execution record eventually marked the run as failed even while lighter status surfaces still reported `RUNNING`.

Relevant server log tail:

```text
[COMPLETION] Execution 606932901669634625 marked as failed due to earlier step failures
Workflow failed: execution_id=606932901669634625, final_step=fetch_assessments:task_sequence
Playbook failed: execution_id=606932901669634625, final_step=fetch_assessments:task_sequence
```

Relevant loop-hydrate evidence from the same run:

```text
[LOOP-HYDRATE] Failed to render loop collection for fetch_assessments epoch=loop_606932901669634625_fetch_assessments_2: 'claim_patients_for_assessments' is undefined
[LOOP-HYDRATE] Restored synthetic collection for fetch_assessments epoch=loop_606932901669634625_fetch_assessments_2 from NATS KV collection_size=100 (step_results unavailable for re-render)
```

The same pattern repeated for later epochs, and the execution progressed through `loop.done` epochs `_1` through `_6` before the SQL-rendering failure surfaced.

## Where It Broke

The unresolved SQL expression matches the `save_page` block in the PFT fixture:

- [repos/noetl/tests/fixtures/playbooks/pft_flow_test/test_pft_flow.yaml](/Volumes/X10/projects/noetl/ai-meta/repos/noetl/tests/fixtures/playbooks/pft_flow_test/test_pft_flow.yaml#L416)
- [repos/noetl/tests/fixtures/playbooks/pft_flow_test/test_pft_flow.yaml](/Volumes/X10/projects/noetl/ai-meta/repos/noetl/tests/fixtures/playbooks/pft_flow_test/test_pft_flow.yaml#L419)

That SQL only works if `iter.patient` is still the claimed row object for the current loop iteration.

## Root Cause

The most likely root cause is iterator payload loss during resumed loop/task-sequence dispatch after cold-state recovery.

The chain is:

1. Cold state rebuild cannot re-render `fetch_assessments.loop.in` from `{{ claim_patients_for_assessments.rows }}` because `step_results` is unavailable.
2. Fix #4 restores only a synthetic collection based on `collection_size`:
   - [repos/noetl/noetl/core/dsl/engine/executor/rendering.py](/Volumes/X10/projects/noetl/ai-meta/repos/noetl/noetl/core/dsl/engine/executor/rendering.py#L174)
3. That synthetic collection is sufficient for loop accounting (`completed_count >= collection_size`) but does not preserve the original patient row payload.
4. At least one resumed `fetch_assessments:task_sequence` command is later created/executed without a valid object at `iter.patient`.
5. Worker-side task-sequence rendering does not fail hard on undefined variables. It catches the render exception and returns the original template string unchanged:
   - [repos/noetl/noetl/worker/nats_worker.py](/Volumes/X10/projects/noetl/ai-meta/repos/noetl/noetl/worker/nats_worker.py#L2797)
   - [repos/noetl/noetl/core/dsl/render.py](/Volumes/X10/projects/noetl/ai-meta/repos/noetl/noetl/core/dsl/render.py#L296)
   - [repos/noetl/noetl/core/dsl/render.py](/Volumes/X10/projects/noetl/ai-meta/repos/noetl/noetl/core/dsl/render.py#L333)
6. Postgres receives raw SQL containing `{{ iter.patient.patient_id }}` and fails with a parser error instead of a structured template-rendering failure.

In short: fix #4 unblocked loop completion, but the synthetic-collection fallback preserves loop cardinality, not iteration payload integrity. The worker then masks the missing-variable error and leaks raw Jinja into SQL.

## Fix Direction

1. Fail fast on unresolved Jinja for Postgres task-sequence SQL.
   - Do not return the original template string on undefined iterator variables for SQL-bound commands.
   - Surface a structured `template_rendering` error before Postgres execution.

2. Do not use synthetic placeholder items for dispatch paths that still require the original loop item payload.
   - Synthetic collections are acceptable for loop accounting and `loop.done` threshold math.
   - They are not sufficient when downstream command rendering still depends on fields like `iter.patient.patient_id`.

3. Separate two recovery modes explicitly:
   - `accounting-only restore`: enough to decide loop completion
   - `dispatch-capable restore`: requires the original loop collection or a per-command persisted iteration payload

4. Preferred implementation options:
   - Restore the real loop collection from NATS KV object storage when dispatch must continue.
   - Or persist the per-iteration payload directly on each command in a way that resumed task-sequence execution never depends on reconstructing the parent collection.

5. Tighten validation around task-sequence loop resumes.
   - If `iter.<iterator>` is not an object matching the loop item contract, fail the command as a render/runtime error before tool execution.

## Compatibility / Notes
- Backward compatible: likely yes for engine semantics, but behavior changes from silent raw-template passthrough to explicit render failure
- Migration required: no
- Config/DSL impact: none expected
- Known risks:
  - forcing strict render failures may surface existing latent template bugs in other task-sequence pipelines
  - restoring full loop payloads may increase NATS/object-store usage versus collection-size-only fallback

## Verification
- Tests run:
  - Fresh distributed PFT execution `606932901669634625` on `d2ad24d9`
  - Confirmed earlier fixes remained active during the same run:
    - re-dispatch guard fix (#2)
    - loop epoch progression fix (#3)
    - synthetic collection restore fix (#4)
- Environments verified:
  - local kind cluster, arm64 image `local/noetl:arm64-d2ad24d9`
- Observability notes:
  - status surfaces were inconsistent (`execute status` and `/status` lagged), but full execution record marked `FAILED`
  - failure surfaced after substantial forward progress (`remaining_count` reached `200`)
