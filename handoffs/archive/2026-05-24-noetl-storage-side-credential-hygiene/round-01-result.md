---
thread: 2026-05-24-noetl-storage-side-credential-hygiene
round: 1
from: codex
to: claude
status: partial
---

# Round 01 Result

This round stopped after Phase A/B by the prompt gate. The storage-side surface is larger than a single safe implementation round because the fix has to change server render timing, command persistence, worker dispatch, state/event/result writers, and binary/shared-cache producer contracts together. I did not open a NoETL PR, did not change the wiki, and did not run live validation.

No secret values were written to this file. All examples below use playbook variable names, table/column names, or placeholders only.

## Phase A — audit

PR #603 is merged into `noetl/noetl` main. Local `repos/noetl` was synced to `origin/main` at `f051d9c27c019afd8eff5997d4471d3e2a7834d2`, which includes merge commit `fb38b07f9bb2ea23d3b03f72d0424d6930aea90d` for the read-boundary redaction fix.

The travel reproducer is still a valid storage-boundary test case:

- `repos/travel/playbooks/itinerary-planner.yaml:46-63` declares `openai_token` and `anthropic_token` keychain entries.
- `repos/travel/playbooks/itinerary-planner.yaml:142-156` passes `{{ keychain.openai_token.api_key | default('') }}` and `{{ keychain.anthropic_token.api_key | default('') }}` into the `extract_turn` Python step.

Audited storage and transit surfaces:

- Server keychain processing: `repos/noetl/noetl/server/keychain_processor.py:78-127` resolves keychain entries, stores them in `noetl.keychain`, then returns resolved data to the lifecycle executor.
- Lifecycle state injection: `repos/noetl/noetl/core/dsl/engine/executor/lifecycle.py:164-175` updates `state.variables` and `state.variables.keychain` with resolved keychain data. This is the first storage leak path because later state/event/command writers consume `state.variables`.
- Lifecycle initialized events: `repos/noetl/noetl/core/dsl/engine/executor/lifecycle.py:184-205` builds `workload_snapshot` from `state.variables` and writes it into `playbook.initialized` and `workflow.initialized` results.
- State projection: `repos/noetl/noetl/core/dsl/engine/executor/state.py:108-125` serializes `variables` into execution state, and `repos/noetl/noetl/core/dsl/engine/executor/store.py:126-175` writes that JSON into `noetl.execution.state`.
- Step result mirrors: `repos/noetl/noetl/core/dsl/engine/executor/state.py:243-244` mirrors step results back into `state.variables`, so any tool result containing a resolved credential can later be persisted as state.
- Command rendering: `repos/noetl/noetl/core/dsl/engine/executor/commands.py:972-1021` server-renders step input and single-tool config before command persistence. If `state.variables.keychain` contains cleartext, keychain templates become cleartext before the worker sees them.
- Command context persistence: `repos/noetl/noetl/core/dsl/engine/executor/commands.py:1058-1067` embeds `render_context` in each `Command`. `repos/noetl/noetl/server/api/core/execution.py:150-181` then writes command context to both `noetl.event.context` and `noetl.command.context`.
- Follow-up command writers: `repos/noetl/noetl/server/api/core/batch.py` and `repos/noetl/noetl/server/api/core/events.py` use the same command context pattern for later command issuance, so the fix cannot be limited to the initial execution endpoint.
- Worker keychain resolution: `repos/noetl/noetl/worker/keychain_resolver.py:378-433` can populate `context.keychain` from templates found in task config, but it depends on those templates surviving command persistence. With the current server pre-render path, they may not.
- Worker tool dispatch: `repos/noetl/noetl/worker/nats_worker.py:1908-2024` prepares render context and calls `_execute_tool`; `repos/noetl/noetl/worker/nats_worker.py:2044-2066` passes the raw tool response through `ResultHandler`.
- Result transport/storage: `repos/noetl/noetl/worker/result_handler.py:141-192` returns small results inline, and `repos/noetl/noetl/worker/result_handler.py:204-267` stores large results while also creating previews and extracted fields.
- Temp/result store: `repos/noetl/noetl/core/storage/result_store.py:263-285` serializes JSON payloads and creates previews; `repos/noetl/noetl/core/storage/result_store.py:287-368` stores them in the selected tier.
- Arrow IPC/shared-cache: `repos/noetl/noetl/core/storage/result_store.py:370-430` stores opaque Arrow IPC bytes and optionally shares them via IPC cache. This boundary cannot reliably scrub secrets without producer-side provenance or decoding the payload.
- Result/temp API writers: `repos/noetl/noetl/server/api/result/endpoint.py:124-161` and `repos/noetl/noetl/server/api/temp/endpoint.py:86-120` accept caller-provided data and write it to the shared store.
- Transient variables: `repos/noetl/noetl/worker/transient.py:420-456` stores arbitrary variable values in `noetl.transient.var_value`.

Conclusion: this is not one writer bug. The main leak originates from resolving keychain data on the server and then treating it as ordinary workflow data. A safe fix must introduce keychain references as a first-class storage representation and delay cleartext materialization until worker/tool execution.

## Phase B — design decisions

Recommended representation:

```json
{"$noetl_ref": {"kind": "keychain", "name": "openai_token", "field": "api_key"}}
```

Properties:

- JSON-native, explicit, and easy to detect recursively.
- Distinguishes keychain references from ordinary dicts and user data.
- Preserves field-level references without writing the resolved value.
- Can be extended later with scope, catalog, execution, version, or provider metadata without changing the outer marker.

Recommended resolution timing:

- Server lifecycle may create and store keychain rows, but must not put resolved keychain values into `state.variables`, event payloads, command contexts, or execution state.
- Server command creation should preserve keychain-dependent values as references, or preserve the original keychain template for worker-side rendering when a string mixes keychain references with other text.
- Worker dispatch should resolve references just before invoking the tool, keep cleartext in memory only, then scrub the resolved keychain namespace before emitting events/results.
- Read-side redaction from PR #603 should remain as a safety net for historical rows and accidental regressions, but storage should not rely on it.

Recommended helper module:

- Add a shared helper such as `noetl/core/credential_refs.py`.
- Include recursive helpers to detect keychain templates, encode pure keychain expressions as `{"$noetl_ref": ...}`, identify mixed expressions that must be deferred, and resolve references at worker dispatch.
- Include storage-boundary helpers for state/event/command/result writers that reject or replace known credential refs before JSON serialization.

Implementation should be split into at least two code rounds:

1. Command/state safety round:
   - Stop `lifecycle.start_execution` from writing resolved keychain data into `state.variables`.
   - Keep `noetl.keychain` storage for resolved credential material.
   - Teach command creation to avoid server-side cleartext rendering for keychain-dependent inputs/config.
   - Strip `keychain` and other resolved credential data from command `render_context`.
   - Resolve refs/templates inside worker dispatch immediately before tool execution.
   - Add regression tests for the travel `extract_turn` input shape.

2. Result/store hardening round:
   - Add recursive storage-boundary checks in event, state, command, result, temp, and transient writers.
   - Define behavior for arbitrary caller-provided cleartext at result/temp API boundaries. Without provenance, this cannot be made perfect by pattern matching alone.
   - Add producer-side handling for Arrow IPC/shared-cache payloads, since byte payloads cannot be scrubbed safely after serialization without parsing and schema-aware policy.

## Phase C — writers patched

Skipped by scope gate. No product code was changed.

The writers that need changes in the next round are:

- `lifecycle.start_execution` keychain injection and initialized event payloads.
- `ExecutionState.to_dict` and state save/load boundaries.
- Server command creation and command context builders.
- Initial and follow-up command persistence endpoints.
- Worker dispatch and result event emission.
- Result/temp/transient stores.
- Arrow IPC producers that can carry secret-bearing rows.

## Phase D — tests

Skipped by scope gate. No test suite was run.

Suggested minimum tests for the implementation round:

- Unit test that `process_keychain_section` no longer causes resolved values to appear in `ExecutionState.variables`.
- Unit test that a pure keychain expression is stored as a `$noetl_ref` object in command context.
- Unit test that a mixed keychain expression is deferred or rejected instead of rendered to cleartext on the server.
- Integration test around the travel `extract_turn` step proving `noetl.event.context`, `noetl.command.context`, and `noetl.execution.state` contain references/placeholders only.
- Worker test proving refs resolve just before tool execution and are absent from emitted `step.exit`/`call.done` events.
- Result store test proving previews/extracted fields do not include credential refs resolved to cleartext.

## Phase E — live validation

Skipped by scope gate. No live cluster validation was run because no implementation was applied.

Suggested live validation after implementation:

- Register a temporary copy of the travel itinerary planner playbook.
- Run 3-5 turns using placeholder-safe inspection only.
- Query `noetl.event.context`, `noetl.event.result`, `noetl.command.context`, `noetl.command.result`, and `noetl.execution.state` for the execution.
- Verify keychain placeholders/references appear where needed and resolved values do not appear.
- Verify the actual LLM-backed step still succeeds, proving worker-side resolution happened at dispatch.

## Phase F — wiki update

Skipped by scope gate. No wiki page was changed because no code behavior was changed.

The implementation round should update `repos/noetl-wiki` in the same PR flow as the code change, documenting:

- Keychain values are stored in `noetl.keychain` and referenced elsewhere by tagged refs.
- Command/state/event/result storage must not contain resolved credential material.
- Tool authors should accept refs/templates and rely on worker dispatch for just-in-time resolution.
- Result/temp/Arrow producers must not serialize credential material into stored outputs.

## Issues observed

- The current server-side render path can erase the worker-side keychain-resolution opportunity by rendering keychain templates before command persistence.
- Some existing logs around worker keychain resolution include resolved keychain data at debug level. That is adjacent to the storage boundary and should be removed or changed while implementing the storage fix.
- Generic result/temp API inputs and Arrow IPC bytes lack provenance. They can store arbitrary caller-provided cleartext values, so the next implementation must be explicit about what is guaranteed for keychain-derived values versus arbitrary user data.
- Historical rows may already contain resolved credential material. PR #603 protects API reads, but this round did not perform database cleanup or migration.

## Manual escalation needed

Open a new implementation round with a narrower first target: keychain references through command/state/event storage and worker dispatch for the travel `extract_turn` path. Treat result/temp/Arrow hardening as a follow-up unless the first implementation proves smaller than expected.

Do not merge any implementation PR until live validation confirms that storage rows contain refs/placeholders only and the workflow still executes successfully.
