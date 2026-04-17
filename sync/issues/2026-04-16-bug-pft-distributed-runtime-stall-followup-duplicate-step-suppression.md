# Follow-Up: Original Loop-Epoch Counter Bug Fixed, Stall Now Narrows to Duplicate-Step Suppression

## Context
This note follows:
- sync/issues/2026-04-16-bug-pft-distributed-runtime-stall-606790043104968712.md
- sync/issues/2026-04-16-bug-pft-distributed-runtime-stall-606790043104968712-hypotheses.md

Validated runtime revision:
- noetl: `0d380689`

Validated local image:
- `local/noetl:arm64-0d380689`

## What This Validation Confirms
The original NATS loop-state counter clamp appears fixed.

Specifically, the previous failure mode was:
- stale loop state reused the same deterministic epoch id,
- `completed_count=100` from the prior epoch survived reset,
- the next claim path saw `scheduled >= collection_size`,
- the loop permanently stopped after the first 100-patient batch.

That exact behavior no longer occurs.

## Clean Validation Run
Authoritative rerun:
- execution_id: `606806784191234620`
- catalog path: `catalog://tests/fixtures/playbooks/pft_flow_test/test_pft_flow@3`

Observed progression:
1. `load_patients_for_assessments` completed normally.
2. `claim_patients_for_assessments` completed normally.
3. `fetch_assessments` ran its first loop epoch and emitted `loop.done`.
4. The engine issued and claimed a second `load_patients_for_assessments` command.
5. That second load step completed with `remaining_count = 900`.

This proves the runtime advanced past the old first-batch deadlock boundary.

## New Failure Boundary
After the second `load_patients_for_assessments` completion, the engine stopped making useful progress again.

What did not happen:
- no second `claim_patients_for_assessments` completion was observed,
- no later non-checkpointer events appeared after the second load cycle.

Most recent useful progress timestamp observed:
- `latest_non_checkpointer = 2026-04-17T05:36:54.800780`

High-signal counters from the run:
- `assessment_load_completions = 2`
- `assessment_claim_completions = 1`

## Direct Evidence
### Event timeline
The ordered `noetl.event` query for execution `606806784191234620` shows:
- first `load_patients_for_assessments` completed at `2026-04-17T05:36:46.393975`
- first `claim_patients_for_assessments` completed at `2026-04-17T05:36:46.498273`
- `fetch_assessments:loop.done` emitted at `2026-04-17T05:36:54.738577`
- second `load_patients_for_assessments` was issued at `2026-04-17T05:36:54.752020`
- second `load_patients_for_assessments` completed at `2026-04-17T05:36:54.791557`
- no second `claim_patients_for_assessments` event followed.

### Status snapshot
During the second load cycle, status showed:
- `current_step = load_patients_for_assessments`
- `patients_needing_assessments_count = 900`

That is the critical proof that the first 100-patient batch was consumed and the workflow re-entered the assessment loader correctly.

### Server log suppression line
Server logs for the same execution include:
- `[NEXT-EVAL] Skipping duplicate command for step 'claim_patients_for_assessments' - already in issued_steps`

This appears immediately after the second `load_patients_for_assessments` command is claimed/completed.

## Narrowed Hypothesis
### P0 Follow-Up: `issued_steps` is stale for non-loop re-entry and suppresses the next claim step
Confidence: High

Current hypothesis:
- the first `claim_patients_for_assessments` invocation adds that step to `issued_steps`,
- the step later completes,
- but the pending marker is not cleared in the state path used for subsequent transition evaluation,
- when the loop returns to `load_patients_for_assessments`, next-arc evaluation matches `claim_patients_for_assessments`,
- the transition layer suppresses it as already pending,
- the workflow stops after the second load step with `remaining_count = 900` and no new claim command.

This is a different failure mode than the original loop-epoch counter merge bug.

## Code Pointers
Primary suppression site:
- `repos/noetl/noetl/core/dsl/engine/executor/transitions.py`
  - duplicate-step suppression around the `issued_steps` check
  - log line: `Skipping duplicate command for step ... already in issued_steps`

Relevant state tracking:
- `repos/noetl/noetl/core/dsl/engine/executor/state.py`
  - `issued_steps` definition
  - `mark_step_completed()` adds to `completed_steps`

Relevant completion handling:
- `repos/noetl/noetl/core/dsl/engine/executor/events.py`
  - `call.done` path stores result and marks step completed
  - no obvious paired removal from `issued_steps` in the same completion path

## Why This Matters
The latest validation materially changes the debugging picture:
- the `NATSKVCache.set_loop_state(... force_replace=True)` change appears to have removed the original first-batch counter-clamp,
- the runtime now reaches the next loopback decision,
- the next blocker is likely generic transition deduplication on re-entrant non-loop steps.

In other words, the original bug was real and fixed, but it exposed the next orchestration defect behind it.

## Suggested Next Fix Checks
1. Verify where `claim_patients_for_assessments` should be removed from `issued_steps` after `call.done`.
2. Confirm whether `completed_steps` alone is intended to make the dedupe guard safe for re-entry.
3. Add a temporary log of `issued_steps` and `completed_steps` immediately before the duplicate-suppression branch in `transitions.py`.
4. Re-run the same `@3` playbook and confirm a second `claim_patients_for_assessments` command is issued after the second load step.

## Exit Criterion For This Follow-Up
For execution `test_pft_flow`, after the first `fetch_assessments:loop.done`:
- the engine must issue a second `claim_patients_for_assessments`,
- `remaining_count` must continue dropping below `900`,
- later data types or later facilities must start, proving the assessment loop is not stuck on re-entry.