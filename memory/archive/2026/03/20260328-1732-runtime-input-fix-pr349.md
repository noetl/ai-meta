# Runtime input/context consistency fix after PR #348

- Date: 2026-03-28 (America/Los_Angeles)
- Repo: `repos/noetl`
- Branch: `kadyapam/dsl-v2-runtime-input-consistency`
- PR: https://github.com/noetl/noetl/pull/349

## Problem fixed

After PR #348 merged fixture migration (`input/output/set`), distributed `/api/execute` still failed with:

`"'Command' object has no attribute 'args'"`

Root cause: server command emission path still used `cmd.args` instead of canonical `cmd.input`.

## Changes implemented

- `noetl/server/api/v2.py`
  - Added helpers to normalize command input and build command context.
  - Switched emitted command context to canonical `input` key.
  - Removed direct `cmd.args` reads in execute/handle_event/batch command issuance.
  - Kept legacy `args` as read alias for backward compatibility.
- `noetl/core/dsl/v2/models.py`
  - Added legacy `args -> input` alias validators on `CommandIssuedPayload` and `Command`.
  - Clarified `result` payload descriptions as control-plane envelopes.
  - Updated doc examples to use `output.*` language.
- `noetl/core/dsl/v2/engine.py`
  - Replaced internal `Command(..., args={})` call sites with `input={}`.
  - Renamed selected command creation parameters/comments to `step_input`/`transition_input` semantics.
- `noetl/core/dsl/v2/parser.py`
  - Updated wording from outcome-handling to output-handling.
- `noetl/worker/v2_worker_nats.py`
  - Renamed top-level command input variable for clarity (`command_input`) while retaining legacy alias support.
- `tests/api/test_v2_command_context_transport.py`
  - Updated canonical tests to use `input`.
  - Added explicit legacy `args` alias acceptance test.

## Validation

- `python3 -m py_compile` passed on all touched files.
- Local kind redeploy succeeded with image `local/noetl:2026-03-28-10-26`.
- `/api/execute` smoke for `tests/fixtures/playbooks/hello_world` now returns `started` with execution id.
- No `cmd.args` attribute errors observed in server logs post-fix.
- Fixture registration succeeded: `139/139` loaded.
- `master_regression_test_parallel` distributed execution now starts (RUNNING), indicating blocker is removed.

## Notes

- Full pytest run wasn’t possible in this local shell due missing `psycopg` module in environment.
