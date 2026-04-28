# Bug — agent playbooks ending in `kind: noop` discard the real result

- Captured: 2026-04-28 (UTC)
- Reporter: Kadyapam (Cowork session)
- Status: open — fixture mitigated, engine-side fix pending
- Severity: medium — silently truncates agent output, GUI terminal renders nothing
- Repo(s): `repos/noetl` (engine), `repos/ops` (fixture pattern)
- Related execution: `615095892923646114` (`automation/agents/kubernetes/runtime` v1, k8s pods command)

## Symptom

User runs `pods` in the GUI terminal under `/mcp/kubernetes`. Execution
`615095892923646114` runs for 56 s, status COMPLETED, all three steps
(`call_mcp`, `summarize`, `end`) in `completed_steps`. But the terminal
shows nothing under "started k8s pods :: execution=...". No error,
no payload.

## Root cause

`repos/ops/automation/agents/kubernetes/runtime.yaml` ended with:

```yaml
- step: end
  desc: End Kubernetes runtime agent execution
  tool:
    kind: noop
```

The engine puts the *terminal* step's output on
`playbook.completed.result`. With `kind: noop`, the terminal step
emits `{step: "end", status: "noop"}`, which is what the GUI
subscribes to and renders. The *actual* MCP tool payload sits on
the `summarize` step's `output.data` and the engine never bubbles it
up to the parent execution row's `result` field
(`/api/executions/{id}` shows `"result": null` even though the
playbook completed cleanly).

This applies to **every** agent playbook that uses `kind: noop` as
its terminal step — not just kubernetes_runtime_agent. Until the
engine fix lands, every such agent has to manually re-emit its
prior step's result from `end`.

## Mitigation (landed)

`noetl/ops` branch `kadyapam/runtime-agent-return-summary`,
commit `5468f2f`:

```yaml
- step: end
  desc: |
    Return the summarized MCP tool result so consumers see the real
    payload instead of {"step": "end", "status": "noop"}.
  tool:
    kind: python
    input:
      summary: '{{ summarize }}'
    code: |
      result = summary
```

After this PR merges and the agent catalog row is re-registered, the
GUI terminal should render the `summarize.text` field as the result
of `pods` / `tools` / `namespaces` / etc.

## Proper engine fix (open)

Two complementary changes in `repos/noetl`:

1. **Bubble the agent's `return_step` output up to the parent
   execution row.** Today `/api/executions/{id}` returns
   `"result": null` for an agent execution that completed; the data
   is only on individual step events. The engine should populate
   the execution row's `result` from
   `<return_step>.output.data` when the playbook completes
   successfully.
2. **`kind: noop` should pass-through, not blank-out.** When the
   terminal step is `kind: noop`, the engine should emit the prior
   step's output on `playbook.completed.result.context` instead of
   `{step: "end", status: "noop"}`. That keeps existing
   noop-terminated playbooks working without forcing every fixture
   to add a python pass-through step.

Either fix on its own is enough; doing both is cleanest.

## GUI follow-up

Even with the engine fix, the GUI's terminal-prompt should be
defensive: when `playbook.completed.result.context` is empty or
looks like a noop ack (`{status: "noop"}`), fall back to reading
the most recent `step.exit` event's `output.data`. That way old
fixtures still produce something visible.

## Verification

After the agent re-registration, run `pods` in the GUI terminal and
confirm:

1. The execution detail page shows the new agent version
   (catalog version 2).
2. The terminal renders the kubernetes pod listing under the "started
   k8s pods" line, not just the "open / report" buttons.
3. `curl -sS .../api/executions/<id>` returns a non-null `result`
   field with `text` containing the pod listing.

## Action items

- [x] Land fixture mitigation in `repos/ops` (`5468f2f`).
- [ ] Push branch, open PR, merge.
- [ ] Re-register `automation/agents/kubernetes/runtime` against the
  kind catalog so version 2 of the resource picks up the fix.
- [ ] Sweep other agent playbooks under `repos/ops/automation/agents/**`
  for `kind: noop` terminal steps and apply the same pattern.
- [ ] Open `noetl/noetl` issue for the engine-side fix
  (return_step → execution.result + noop pass-through).
- [ ] Open `noetl/gui` issue for the defensive fallback in the
  terminal-prompt component.
