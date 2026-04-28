# Bug — MDS batch worker `end` step renders `{{ start.* }}` literally; sub-playbook reported failed despite work completing

- Captured: 2026-04-28 (UTC)
- Reporter: Kadyapam (Cowork session)
- Status: open
- Severity: medium — data work completes, but UI/event status reports the sub-playbook as failed
- Repo(s): `repos/noetl` (engine/render), `repos/e2e` (fixture), `repos/gui` (status display)
- Related execution: `614782701987430447` (kind, NodePort `30555` test API server)
- Related parent flow: `tests/fixtures/playbooks/pft_flow_test/test_pft_flow` execution `614768929377878676`

## Symptom

Sub-playbook `tests/fixtures/playbooks/pft_flow_test/test_mds_batch_worker` finishes with:

- Status: `failed`
- Start: `2026-04-27 22:43:29`
- End:   `2026-04-27 22:45:10`
- Error: `invalid literal for int() with base 10: '{{ start.batch_number }}'`
- URL: `http://localhost:38081/execution/614782701987430447`

The user observation is that the actual MDS fetch + save work for the batch completed successfully; only the terminal `end` step blew up.

## Suspected root cause

In `repos/e2e/fixtures/playbooks/pft_flow_test/test_mds_batch_worker.yaml`, the final `end` step is:

```yaml
- step: end
  desc: Batch worker complete
  tool:
    kind: python
    input:
      batch_number: '{{ start.batch_number }}'
      offset: '{{ start.offset }}'
    code: |
      result = {
          "status": "completed",
          "batch_number": int(batch_number) if batch_number else 0,
          "offset": int(offset) if offset else 0,
      }
```

The reaching arc to `end` from `fetch_mds_details` is `when: '{{ event.name == "loop.done" }}'`. After the parallel loop closes, the python tool input arrives with the literal string `'{{ start.batch_number }}'` instead of the rendered `start.result.batch_number` (or equivalent).

The same `start` reference *does* render correctly earlier in the playbook for the postgres step:

```yaml
- step: fetch_batch_ids
  tool:
    kind: postgres
    query: |
      ...
      OFFSET {{ start.offset }}
      LIMIT {{ start.batch_size }};
```

So `start.*` refs work pre-loop but not in the post-`loop.done` `end` step. That points at a render-context regression where the `start` step's output is not present in the render scope when an arc fires off `event.name == "loop.done"`.

## Hypotheses (rank-ordered)

1. **Loop-done arc render scope drops prior step outputs.** When the `end` step is dispatched off the synthetic `loop.done` event, the engine builds the input render context from the loop's output but does not re-attach earlier step results (notably `start`). Earlier steps (`fetch_batch_ids`, `normalize_batch`) are dispatched off normal arcs that include the prior chain.
2. **Cursor-loop replay clears non-loop step outputs.** With the cursor loop infrastructure landed (PR #383) and `loop.done` synthesized from `call.done`, the execution context fed to the next step's input renderer may only carry the loop step's last output, not the cumulative scope.
3. **`start` step output projection issue.** The `start` step uses Python `result = {...}`, and the engine may project that as `start.result.batch_number` rather than `start.batch_number` — the SQL step appears to alias either form, but the python input render path in the `end` step may resolve the string literally if the dotted lookup misses.

## Verification plan

1. Pull execution `614782701987430447` event/command timeline:
   - `psql ... -c "SELECT event_id, name, step_name, output -> 'data' FROM noetl.event WHERE execution_id = 614782701987430447 ORDER BY event_id;"`
   - confirm `start.result` payload is well-formed and inspect the `command` for the `end` step to see the rendered (or unrendered) input.
2. Reproduce locally by re-running `tests/fixtures/playbooks/pft_flow_test/test_mds_batch_worker` with explicit workload values and compare context dumps in the `start`-step result vs `end`-step input.
3. Cross-check against another fixture that exits a parallel loop into a python step (e.g. `tooling_non_blocking`) — does it also lose `start.*` after `loop.done`?

## Mitigation options

- **Quick fix in fixture (unblocks PFT flow validation):** change the `end` step to reference workload directly:
  ```yaml
  input:
    batch_number: '{{ workload.batch_number }}'
    offset: '{{ workload.offset }}'
  ```
  This sidesteps the render scope question and lets the sub-playbook complete cleanly while the engine fix is investigated.
- **Engine fix (preferred long-term):** make the input renderer for `loop.done`-arc destination steps include the full step-output scope, not just the loop step output. Add a regression test under `tests/integration/dsl/v2/` that exits a parallel loop into a python step which references an early step.

## Out of scope (but worth tracking)

- The GUI in `repos/gui` v1.1.1 surfaces sub-playbook status from the engine event stream; even if the engine emits `failed`, a separate UX question is whether sub-playbook status should be merged with parent status or whether partial-completion can be visualized. Defer to a follow-up once the engine bug is resolved.

## Action items

- [ ] Reproduce against execution `614782701987430447` with SQL pull from `noetl.event`/`noetl.command`.
- [ ] Apply fixture-level mitigation to `repos/e2e/fixtures/playbooks/pft_flow_test/test_mds_batch_worker.yaml` and rerun the parent flow.
- [ ] Open `noetl/noetl` issue + PR for the render-scope fix once root cause is confirmed.
- [ ] Note in `memory/inbox/2026/04/...` and update `memory/current.md` Open Items.
