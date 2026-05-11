# Handed noetl agent → MCP result hydration fix to Codex (engine round — Claude coded, Codex verifies + deploys)

- date: 2026-05-11T09:00:00Z
- tags: noetl-engine, agent-executor, sub-execution-hydration, item-11, codex-handoff

## Round goal

Fix the activities NoETL-reference truncation bug surfaced in item #7's
Amadeus investigation. Engine-level change in `noetl/tools/agent/executor.py`.

This is the first noetl-engine round of the session — earlier rounds were
ops+docs. Claude coded the fix + tests directly; Codex's job is to verify,
test, ship the PR, deploy to kind, smoke, deploy to GKE, smoke again.

## The bug, in one paragraph

`/api/executions/{id}/status` compacts `state.variables` (see
`_compact_status_variables` in noetl/server/api/core/utils.py). Any value
over `_STATUS_VALUE_MAX_BYTES` becomes a `{_truncated, _original_size_bytes,
_preview}` stub. The agent executor's `_wait_for_sub_execution_terminal`
polls this endpoint, and `_invoke_noetl_playbook` uses the result as
`envelope.data`. Large MCP envelopes (e.g. Amadeus activities returning
200 with many items) get silently truncated. Travel runtime's
`when: amadeus_via_mcp_activities.data.ok | default(false)` evaluates
against the truncated stub (no .ok field present), routing successful
executions to render_amadeus_failure.

## The fix

New helper `_fetch_sub_execution_terminal_result(execution_id)` in the
agent executor. Fetches `/api/executions/{id}/events?page_size=500&page=1`
(uncompacted), walks for the highest-event_id command.completed /
step.exit / call.done event whose node_name isn't a boundary (start/end),
returns its `result.context`. Best-effort: returns None on network failure
or no terminal-step event.

Wiring in `_invoke_noetl_playbook`: `envelope.data` priority order is now
`_fetch_sub_execution_terminal_result(sub_execution_id) → sub_terminal →
sub_result.get('data')`. Only invokes the new helper when sub_execution_id
is truthy.

3 unit tests cover: picks-last-terminal-step (highest event_id wins,
boundary nodes skipped), returns-None-when-no-terminal (fallback works),
swallows-network-failure (no exception leaks).

## Why this is the right architectural shape

The travel runtime ALREADY worked around this for Vertex AI and Ollama
via `_fetch_vertex_child_context` and `_fetch_ollama_child_context`
helpers that walk events directly. The pattern is correct; it just needs
to live in the noetl engine instead of being repeated by every playbook
that does agent → MCP hops.

After this fix lands:
- Amadeus activities hydrate correctly (item #11 goal).
- Future agent → MCP hops at any payload size work without per-playbook workarounds.
- The travel runtime's existing workarounds become belt-and-suspenders
  (no longer load-bearing). Their removal is a future cleanup round, NOT
  in scope here.

## Why Claude coded this directly

The user said "do 11 - give me a prompt, or code yourself, and give a
prompt to codex to verify and deploy in local and then in gke".

Coding directly let me:
1. Ground the design in actual file inspection (found the exact bug location).
2. Get the wiring precedence right (events → status → dispatch).
3. Write tests that exercise the new helper's contract.
4. Hand Codex a focused review + deploy round rather than a from-scratch
   implementation round (which would have meant Codex re-doing my
   investigation).

The diff is small enough (~250 lines combined across executor + tests)
that Codex can verify it in one read.

## Phases (8)

1. Verify Claude changes (read diff, confirm only the two expected files).
2. Run unit tests (existing + 3 new).
3. noetl PR + semantic-release auto-tag.
4. Deploy to local kind.
5. Kind smoke targeting activities (real data OR correctly-routed failure).
6. Deploy to GKE.
7. GKE smoke 4-provider matrix.
8. ai-meta pointer bump.

## Cap

1 noetl PR. No ops/docs/gui changes in this round.

## Bridge artefacts

- `bridge/inbox/delegated/20260511-090000-noetl-agent-result-hydration.task.json`
- `scripts/noetl_agent_result_hydration_msg.txt`

## Files Claude modified in repos/noetl

- `noetl/tools/agent/executor.py` — new helper + wiring change. ~120 net lines added.
- `tests/tools/test_agent_executor.py` — 3 new tests. ~120 net lines added.

## What might block GREEN

- **Amadeus test API still 5xx**: If activities returns 500 today, we can't
  prove the hydration via the activities path directly. Bridge task includes
  a fallback: synthetic test via mcp/ollama with a long-form prompt to
  exercise the truncation threshold.
- **Existing test regression**: If the wiring change inadvertently breaks an
  existing test, Codex stops and reports. Don't blow through regressions.
- **/api/executions/{id}/events shape drift**: The helper assumes `events`
  array with `event_id`, `event_type`, `node_name`, `result.context` keys.
  If the event row shape has changed since I last read it, helper returns
  None → fallback to current behaviour. Safe.

## What's actually left after this lands

Just one item — Amadeus production API switch (item #12). Pure ops change,
delicate because production smokes cost real money. Future round when
production-data smokes are wanted.

## Trigger prompt for Codex (paste this in after pushing)

```
Claude coded an engine fix for the activities NoETL-reference truncation bug
(item #7's side finding). Verify the diff, run tests, ship the PR, deploy to
kind, smoke (activities should hydrate), deploy to GKE, smoke again.

Bridge task: bridge/inbox/delegated/20260511-090000-noetl-agent-result-hydration.task.json
Prompt details: scripts/noetl_agent_result_hydration_msg.txt
Result file: bridge/outbox/20260511-090000-noetl-agent-result-hydration.result.json

Claude's diff is bounded to:
  - noetl/tools/agent/executor.py (new _fetch_sub_execution_terminal_result
    helper + wiring change in _invoke_noetl_playbook)
  - tests/tools/test_agent_executor.py (3 new tests)

Run all 8 phases per the bridge task: verify diff → run unit tests → noetl PR
→ kind deploy → kind smoke targeting activities → GKE deploy → GKE 4-provider
smoke matrix → ai-meta pointer bump (stage, don't push).

Architectural rules: don't modify anything beyond Claude's two files unless a
test breaks; don't remove the travel runtime's existing workarounds
(_fetch_vertex_child_context / _fetch_ollama_child_context — belt-and-suspenders);
don't change the priority order in the wiring (events → status → dispatch);
don't echo full payloads. No git push from ai-meta.

If Amadeus 5xx blocks activities-path testing on smoke day, use a synthetic
long-form prompt to mcp/ollama to exercise the truncation threshold instead.
```
