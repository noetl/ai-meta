# MDS batch worker end step template not hydrated after loop.done
- Timestamp: 2026-04-28T06:09:23Z
- Author: Kadyapam
- Tags: bug,noetl,e2e,pft,render,loop,gui,observability

## Summary
Sub-playbook `tests/fixtures/playbooks/pft_flow_test/test_mds_batch_worker` finished its real work (HTTP fetches + Postgres saves) but the terminal `end` step blew up rendering `{{ start.batch_number }}` literally — `int()` was handed the unrendered template string. Net effect: GUI v1.1.1 marks execution `614782701987430447` as `failed` although the batch's data work succeeded. The same `start.*` references render fine in pre-loop steps (`fetch_batch_ids` SQL uses `{{ start.offset }}` / `{{ start.batch_size }}`), so the failing site is specifically the python step reached via the `loop.done` arc. Captured a sync issue with hypotheses + verification plan in `sync/issues/2026-04-28-bug-mds-batch-worker-end-step-template-hydration.md`.

## Actions
- Inspected fixture `repos/e2e/fixtures/playbooks/pft_flow_test/test_mds_batch_worker.yaml`; identified `end` step input mapping `batch_number: '{{ start.batch_number }}'` / `offset: '{{ start.offset }}'` as the literal pass-through.
- Filed `sync/issues/2026-04-28-bug-mds-batch-worker-end-step-template-hydration.md` with three ranked hypotheses (loop-done arc render scope drop / cursor-loop replay scope drop / start-step result projection) and a verification + mitigation plan.
- Recommended fixture-level workaround (`{{ workload.* }}` instead of `{{ start.* }}`) to unblock PFT regression and isolate the engine bug.

## Repos
- `repos/noetl`: render/loop-done dispatch on or near `f4c221af`; fixtures pinned via `repos/e2e` `501dcc0`.
- `repos/e2e`: `fixtures/playbooks/pft_flow_test/test_mds_batch_worker.yaml` is the candidate for the fixture mitigation.
- `repos/gui`: `v1.1.1` (`e3bfea2`) surfaces the failed status — UX question deferred until engine bug is resolved.

## Related
- Parent execution: `614768929377878676` (RUNNING) for `tests/fixtures/playbooks/pft_flow_test/test_pft_flow`.
- Failing sub-execution: `614782701987430447` (`failed` despite successful batch work) — `http://localhost:38081/execution/614782701987430447`.
- Test API server: `paginated-api.test-server.svc.cluster.local:5555`, NodePort `30555`, pod `paginated-api-586794ddb5-dfv57`.
- GUI release note: `repos/gui` v1.1.1 — terminal-style prompt UX in catalog, MCP terminal commands routed through agents (PRs #11/#12).
