---
date: 2026-05-05T15:37:29Z
title: Gap 1 follow-up — worker tool_error carve-out for kind:agent
tags: [noetl, gap-1, worker, agent-envelope, tool-error, spike, carve-out]
---

## Context

Codex's autonomous deploy of v2.35.3 returned RED on the spike e2e
(bridge/outbox/codex-spike-green-validation.md). The v2.35.3 fix
(envelope preservation + sub-execution wait, ai-meta/scripts/gap1_envelope_wait_msg.txt)
worked architecturally:

- envelope shape arrived correct: `{status: "error", framework:
  "noetl", entrypoint, error: {kind: "agent.execution", code:
  "PLAYBOOK_FAILED"}, execution_id}`
- the inner sub-playbook completed and returned a proper failed
  envelope

But a NEW downstream bug surfaced: the parent playbook was marked
FAILED *before* `extract_envelope` could run. Events showed:

```
command.failed   trigger_failure   FAILED
step.exit        trigger_failure   COMPLETED
call.error       trigger_failure   FAILED
command.issued   extract_envelope  PENDING   <-- never executed
```

## Root cause

`nats_worker.py:_execute_step` post-tool-execution block (lines
1990-2030) is generic across tool kinds. It coerces
`response.status == 'error'` into `tool_error` for ALL kinds. But
for `tool: kind: agent`, the envelope IS the contract — its
`status: "error"` describes the SUB-execution outcome, not a
step-level failure of the dispatcher. The dispatcher succeeded:
it produced a well-formed envelope.

Translating envelope.status into a step failure terminates the
parent workflow before downstream steps can read the envelope,
defeating the entire contract:

- extract_envelope (the spike's pattern) can't run
- auto_troubleshoot consumers can't surface error.diagnosis
- case blocks routing on `result.status == 'error'` get bypassed

## Fix

Carve out `tool_kind == "agent"` from the tool_error coercion:

```python
is_agent_envelope = (str(tool_kind or "").strip().lower() == "agent")
if isinstance(response, dict) and not is_agent_envelope:
    if response.get('status') in ('error', 'failed'):
        ...
```

Effect: agent envelopes flow straight to call.done. Downstream
steps receive the envelope via the normal `{{ steps.<step>.result }}`
path. Users route on shape (`result.status`, `result.error.kind`)
via case blocks if they want failure routing.

## Artifacts (in ai-meta/scripts/)

- **gap1_carveout.patch** — 24-line unified diff for
  noetl/worker/nats_worker.py:1990-2030
- **gap1_carveout_msg.txt** — comprehensive commit message
  documenting the bug, fix, scope, and tests
- **agent_envelope_carveout_smoke.py** — 8-test smoke validating
  the carve-out is wired in and behaves correctly. Includes:
  - static check of source for `is_agent_envelope` flag
  - kind:agent envelope → no tool_error
  - kind:agent nested data error → no tool_error
  - kind:http error → tool_error (unchanged)
  - kind:task_sequence failed → tool_error (unchanged)
  - kind:postgres nested data error → tool_error (unchanged)
  - case-insensitive matching
  - unknown / None tool_kind → tool_error (default)

Smokes status (ai-meta/scripts):
- agent_envelope_carveout_smoke: 8/8 (after patch applied)
- auto_troubleshoot_smoke: 9/9
- optional_ai_smoke: 6/6

## Bridge task to Codex

bridge/inbox/delegated/20260505-153729-gap1-carveout-spike-green.task.json
— goal-directed, max_iterations=8, approval=auto. Codex applies
patch → runs smokes → commits/pushes/merges PR → waits for v2.35.4
release → deploys via `noetl exec noetl/lifecycle/bump_image
--runtime distributed` (NOT raw kubectl) → re-runs spike →
verifies GREEN.

Success pattern: `GOAL: GAP1_CARVEOUT_GREEN` (server tag = v2.35.4
AND worker tag = v2.35.4 AND spike assertion prints GREEN).

## Why this design

The carve-out scope is ONLY tool_kind == "agent". Every other
tool kind keeps its existing behaviour (http error → tool_error,
postgres nested error → tool_error, task_sequence failed →
tool_error, etc.). No backward incompatibility for existing
flows. This makes the worker behaviour match the documented
agent envelope contract that callers were already programming
against.

## Refs

- bridge/outbox/codex-spike-green-validation.md (RED report
  that surfaced this downstream bug)
- ai-meta/scripts/gap1_envelope_wait_msg.txt (v2.35.3 commit
  message for the prior envelope+wait fix)
- noetl/noetl#407 (Gap 1 — original framework=noetl path)
- noetl/noetl#408 (Gap 4.1 — auto-troubleshoot hook)
- noetl/noetl#411 (v2.35.3 — envelope preservation + wait)
- noetl/noetl#PENDING (this carve-out — to be opened by Codex)
