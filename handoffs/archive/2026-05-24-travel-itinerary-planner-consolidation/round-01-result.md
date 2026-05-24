---
thread: 2026-05-24-travel-itinerary-planner-consolidation
round: 1
from: codex
to: claude
status: completed
completed: 2026-05-24T19:56:00Z
---

# Result: itinerary-planner consolidation

## Summary

Completed Phases A-E.

- Ops PR: https://github.com/noetl/ops/pull/118
- Travel PR: https://github.com/noetl/travel/pull/51
- Both PRs are draft PRs. Neither was merged.
- Travel wiki pushed: `c55d8d730394d9a19eea689c7155fd721afabbae`
- Ops wiki pushed: `be047440d61e063c13fbe55ff9aedbba0a2d5968`
- Live temporary path validated: `muno/playbooks/itinerary-planner-consolidated`
- Existing live path updated after validation: `muno/playbooks/itinerary-planner` version 40

## Phase A Survey

Initial itinerary planner shape:

- Declared workflow steps: 24
- Firestore MCP parent steps: 12
- Provider-backed turn shape before consolidation: separate parent steps for input event, slot projection, slot event, tool-call event, tool response, API replay doc, widget event, chat event, and calendar docs.

Existing Firestore MCP methods:

- `set_doc`
- `get_doc`
- `query_collection`
- `delete_doc`
- `append_event`
- `replay_events`

Firestore MCP auth/error behavior:

- Uses ADC / Workload Identity via google-auth with datastore scope.
- Cleans document paths with `_clean_path`.
- Returns the existing MCP-shaped `_ok` / `_error` envelopes.
- `append_event` allocates `seq` with a transaction and redacts sensitive payload keys.

Baseline observations from the live cluster:

| Execution | Path | Status | Duration |
|---|---|---:|---:|
| `633453069384024536` | `muno/playbooks/itinerary-planner` | completed | 10.749s |
| `633596040792244620` | `muno/playbooks/itinerary-planner` | completed | 442.219s |
| `633631566496792709` | `muno/playbooks/itinerary-planner` | completed | 624.830s |

The same execution listing also showed many stale child `automation/agents/mcp/firestore` executions in `RUNNING`, matching the incident context.

## Phase B Ops Change

Branch: `kadyapam/mcp-firestore-batch-methods`

Commit: `0f7e2a9a1f462cf1da2161840de6f3198da0480e`

Added Firestore MCP tools:

- `batch_set_docs(items|docs)`
- `batch_get_docs(items|paths)`
- `batch_append_events(items|events)`

Implementation choice:

- Internal fan-out over the existing single-item helpers.
- Did not use native Firestore batch write.
- Reason: this preserves current `append_event` transaction/seq/redaction behavior and current MCP result/error envelopes while still removing parent-side NoETL step overhead.

Partial failures return a 207-style MCP error with item-indexed details.

## Phase C Travel Change

Branch: `kadyapam/itinerary-planner-consolidation`

Commit: `5de03968a0e790b613baae2bb4649a6d93a05777`

Updated shape:

| Metric | Before | After |
|---|---:|---:|
| Declared workflow steps | 24 | 14 |
| Provider-backed turn | about 18 executed steps | 11 executed steps |
| Render-only turn | about 10 executed steps | 8-9 executed steps |
| Firestore MCP parent steps in provider-backed turn | about 8 | 4 |

Consolidated steps:

- `persist_turn_docs_atomically` uses `batch_set_docs`.
- `append_turn_events_atomically` uses `batch_append_events`.
- `persist_render_docs_atomically` uses `batch_set_docs`.
- `append_render_events_atomically` uses `batch_append_events`.

Behavioral surfaces preserved:

- Widget envelopes remain `{schema_version, widget_type, variant, payload}`.
- Slot projection remains `chat_threads/<id>/slot_state/current`.
- API replay docs remain `chat_threads/<id>/api_calls/<call_id>`.
- Event stream remains under `chat_threads/<id>/events` with the same event types and sequence semantics.
- Provider policy/retry behavior remains in provider MCP playbooks.

Data-flow note:

- The input event is now appended in the same batched turn-event call as `agent_slot_update` and optional `agent_tool_call`, after extraction has computed the batch payload.
- Runtime validation found template transport could drop the normalized input event object, so `extract_turn` now reconstructs the same user event shape from stable inputs when needed. The persisted event order remains `user_message` before the agent events.

## Live Validation

Cluster:

- `gke_noetl-demo-19700101_us-central1_noetl-cluster`
- `gateway/gateway`: 1/1
- `noetl/noetl-server`: 1/1
- `noetl/noetl-worker`: 3/3

Registration:

- Firestore MCP registered as `automation/agents/mcp/firestore` version 7.
- Temporary consolidated playbook registered as `muno/playbooks/itinerary-planner-consolidated` version 2.
- After temporary validation passed, existing `muno/playbooks/itinerary-planner` registered as version 40.

Synthetic thread:

- `chat_threads/codex-consolidated-v2-1779648653`

| Turn | Execution | Widget | Steps | Duration |
|---|---|---:|---:|---:|
| Destination + party + dates | `634023187587531501` | `place_list` | 11 | 12.494s |
| Flight options | `634023313844469780` | `flight_list` | 11 | 15.213s |
| Schedule view | `634023462213779789` | `calendar_view` | 8 | 8.846s |

Firestore spot checks:

- `chat_threads/codex-consolidated-v2-1779648653/slot_state/current` exists.
- `chat_threads/codex-consolidated-v2-1779648653/api_calls` contains 2 replay docs.
- Event collection contains 16 events in order:
  - turn 1: `user_message`, `agent_slot_update`, `agent_tool_call`, `agent_tool_response`, `agent_widget_emit`, `agent_chat`
  - turn 2: `user_message`, `agent_slot_update`, `agent_tool_call`, `agent_tool_response`, `agent_widget_emit`, `agent_chat`
  - turn 3: `user_message`, `agent_slot_update`, `agent_widget_emit`, `agent_chat`

Latency result:

- The <2s target was not met on this GKE validation run.
- The structural step reduction is real, but live duration stayed in the same rough range as the warm baseline for provider-backed turns.
- This points to remaining platform/runtime overhead outside the playbook consolidation: nested child completion accounting, event persistence, and queue/worker scheduling.

## Local Validation

Travel:

- `npm test` passed: 10 files, 21 tests.
- `npm run type-check` passed.
- `npm run lint` passed.
- `npm run smoke:widgets` passed for 24 widget envelopes.
- `npm run build` passed.

YAML:

- `repos/travel/playbooks/itinerary-planner.yaml` parsed successfully.
- `repos/ops/automation/agents/mcp/firestore.yaml` parsed successfully.

Security/prose checks:

- No service-account JSON added.
- No literal provider token added.
- New prose avoids the banned word from `agents/rules/writing-style.md`.

## Wiki Updates

Travel wiki:

- Updated `playbook-itinerary-planner.md`.
- Commit: `c55d8d730394d9a19eea689c7155fd721afabbae`
- Covered the 14-step shape, batch method use, measured GKE validation, and preserved event/widget surfaces.

Ops wiki:

- Added `agents-mcp-firestore.md`.
- Updated `Home.md` and `_Sidebar.md`.
- Commit: `be047440d61e063c13fbe55ff9aedbba0a2d5968`
- Covered existing Firestore MCP methods, new batch methods, error shape, event semantics, and how the playbook MCP path differs from the gateway subscription sidecar path.

## PRs

Ops PR:

- https://github.com/noetl/ops/pull/118
- Draft.
- Documents method signatures, fan-out strategy, live validation, wiki link, and travel PR.

Travel PR:

- https://github.com/noetl/travel/pull/51
- Draft.
- Documents step count before/after, live timings, unchanged surfaces, ops dependency, and wiki link.

## Issues / Follow-Ups

1. The <2s target was not achieved. The next useful work is platform/runtime profiling around nested playbook completion and worker event write overhead.
2. The NoETL execution listing still shows many old child MCP executions as `RUNNING` after parent completion. This existed before the change and should be investigated separately.
3. `noetl status --json` includes resolved keychain values in `variables`. I avoided copying those values into PRs, wiki pages, and this result, but the status endpoint itself should be reviewed for redaction.
4. Because the code PRs are unmerged, ai-meta submodule pointers were not intentionally bumped to the new ops/travel branch SHAs.

