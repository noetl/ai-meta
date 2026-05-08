---
date: 2026-05-08T05:16:19Z
title: PFT action-batch path GREEN on GKE and local kind; local deploy helper fixed to use e2e test-server
tags: [pft, e2e, local-kind, podman, ops, memory, speedup]
---

## Outcome

GREEN. The PFT fixture's current action-controlled batch path
processes 10,000 patients far faster than the old cursor-heavy
shape, and the result is now documented and validated on both
GKE and local kind.

## Proven executions

GKE:

- Cluster: `gke_noetl-demo-19700101_us-central1_noetl-cluster`
- NoETL server/worker: `ghcr.io/noetl/noetl:v2.37.1`
- Fixture server: `ghcr.io/noetl/test-server:e2e-3b7dde6`
- Catalog version: `fixtures/playbooks/pft_flow_test/test_pft_flow@24`
- Execution: `621993877326528945`
- Duration: `112.98s` (`1m 53s`)
- Status: `COMPLETED`
- Verification probe: `621995558017696648`
- Tables: all five patient domains at `10000`; queues all
  `10000 done`; MDS `10000/10000`; validation log `10` rows
  with per-facility `1000/1000`.

Local kind:

- Cluster/context: `kind-noetl`
- Podman machine: `noetl-dev`
- NoETL server/worker: `ghcr.io/noetl/noetl:v2.37.1`
- Fixture server loaded into kind: `localhost/local/test-server:e2e-6970342`
- Catalog version: `fixtures/playbooks/pft_flow_test/test_pft_flow@1`
- Execution: `622010462971888356`
- Duration: `54.459s` (`54s`)
- Status: `COMPLETED`
- Verification probe: `622011140586864733`
- Tables: all five patient domains at `10000`; queues all
  `10000 done`; MDS `10000/10000`; validation log `10` rows
  with per-facility `1000/1000`.

## What changed architecturally

The old PFT fixture made NoETL orchestrate tiny units:

```
claim one patient -> fetch one page -> save one page -> mark queue -> repeat
```

The current fixture makes NoETL orchestrate bounded action-controlled
batches:

```
claim 25 patients for one data type
-> fetch all fixture rows through one http action
-> save all rows through one postgres action
-> mark patient queue + batch queue done
-> 16 slots repeat until empty
```

This keeps the user-required control boundary: no Python worker gets
direct database access. The hot path uses declared NoETL `postgres`
and `http` actions plus `task_sequence` policy.

## Documentation landed

`repos/e2e/fixtures/playbooks/pft_flow_test/SPEEDUP_EXPLANATION.md`
was added and then updated with local-kind validation evidence.

e2e commits:

- `6970342 docs(pft): explain action-controlled speedup`
- `6d74791 docs(pft): add local kind speedup validation`

ai-meta pointer commit:

- `ccda211 chore(sync): bump e2e for PFT speedup docs`

## Local deploy helper follow-up

While deploying to local kind, the ops helper
`automation/development/noetl.yaml` failed because it still built the
test-server image from `repos/noetl/docker/test-server/Dockerfile`,
whose Dockerfile points at the stale noetl fixture path. The current
PFT batch endpoint lives in `repos/e2e`.

Fix opened:

- `noetl/ops#47` — `fix(dev): build local test-server from e2e fixtures`

The PR:

- adds workload knob `e2e_repo_dir: "../e2e"`;
- prefers `../e2e/docker/test-server/Dockerfile` when available;
- keeps `../noetl/docker/test-server/Dockerfile` as fallback;
- removes the remaining Colima references from the helper
  (Podman-only convention);
- removes deprecated `kubectl set image --record=false`;
- quiets scary direct `kind load docker-image` errors before the
  podman archive fallback.

Validation for ops#47:

```
noetl run automation/development/noetl.yaml \
  --runtime local \
  --set action=deploy \
  --set noetl_repo_dir=../noetl \
  --set e2e_repo_dir=../e2e \
  --set registry=ghcr.io/noetl \
  --set image_name=noetl \
  --set image_tag=v2.37.1 \
  --set image_pull_policy=Always \
  --set podman_machine=noetl-dev
```

The helper completed successfully; `http://127.0.0.1:8082/api/health`
returned `{"status":"ok"}`, and
`http://127.0.0.1:32555/api/v1/pft/batch/demographics?...`
returned batch rows.

## Future reminders

- For PFT local-kind validation, use Podman only. Do not mention or
  use Colima.
- `repos/e2e` owns the current fixture server source used by the PFT
  batch endpoint. Local deploy helpers must not assume the noetl repo
  has the newest test-server fixture.
- The 30-minute local behavior was the old execution shape, not an
  unavoidable local-kind ceiling. The current action-batch shape
  completed 10,000 patients locally in under one minute.

## Post-merge ops#47 validation

After the user merged `noetl/ops#47`, `repos/ops` was fast-forwarded
to:

```
abe52cf fix(dev): build local test-server from e2e fixtures (#47)
```

The merged `automation/development/noetl.yaml` helper was run again
from `main`:

```
noetl run automation/development/noetl.yaml \
  --runtime local \
  --set action=deploy \
  --set noetl_repo_dir=../noetl \
  --set e2e_repo_dir=../e2e \
  --set registry=ghcr.io/noetl \
  --set image_name=noetl \
  --set image_tag=v2.37.1 \
  --set image_pull_policy=Always \
  --set podman_machine=noetl-dev
```

Merged-helper deploy completed successfully. Health checks:

- `http://127.0.0.1:8082/api/health` returned `{"status":"ok"}`.
- `http://127.0.0.1:32555/api/v1/pft/batch/demographics?...`
  returned batch rows.
- NoETL server/worker remained on `ghcr.io/noetl/noetl:v2.37.1`.
- Test server image in local kind: `localhost/local/test-server:latest`.

Fresh local PFT run after merged helper:

- Catalog version: `fixtures/playbooks/pft_flow_test/test_pft_flow@2`
- Execution: `622020352981336195`
- Duration: `114.213s` (`1m 54s`)
- Status: `COMPLETED`
- Final `check_results`: `passed`
- Verification probe: `622021510458245712`
- Tables: all five patient domains at `10000`; queues all
  `10000 done`; MDS `10000/10000`; validation log `10` rows
  with per-facility `1000/1000`.

ai-meta should carry the ops pointer to `abe52cf` after this merge.

## Regression addendum

After the merged-helper local run, an additional regression pass was
run from ai-meta/noetl.

AI-meta smoke scripts:

- `agent_envelope_carveout_smoke.py`: `8/8` passed.
- `gap41_diagnosis_wait_smoke.py`: `7/7` passed.
- `auto_troubleshoot_smoke.py`: `9/9` passed.
- `optional_ai_smoke.py`: `6/6` passed.
- `live_vs_persisted_parity_smoke.py` static mode: `3/3` passed.
- `worker_workload_forwarding_smoke.py`: `8/8` passed.
- `playbook_as_mcp_smoke.py`: `8/8` passed.
- `ollama_bridge_smoke.py`: `9/9` passed.

The untracked local `scripts/exposes_as_mcp_smoke.py` failed in its
synthetic Pydantic harness with `PlaybookMetadata is not fully
defined`; direct product import and validation of
`noetl.core.dsl.engine.models.executor.PlaybookMetadata` succeeded.
Treat this as smoke-harness drift, not a PFT or product regression.

Targeted noetl pytest regression subset:

```
.venv/bin/pytest \
  tests/worker/test_control_context_projection.py \
  tests/tools/test_agent_executor.py \
  tests/worker/test_worker_batch_emit.py \
  tests/worker/test_worker_claim.py \
  tests/worker/test_task_sequence_executor.py \
  tests/test_worker_pool_scaling.py
```

Result: `39 passed, 2 failed`.

Failures:

- `tests/worker/test_worker_batch_emit.py::test_emit_batch_events_externalizes_large_response_payload`
  still expects an externalized top-level `response` field to be absent
  after the worker builds the strict `result` reference envelope. The
  current worker keeps a lightweight `response._ref` pointer while also
  emitting `result.reference`. This is unrelated to PFT throughput but
  should be reconciled so the transport-envelope contract is explicit.
- `tests/test_worker_pool_scaling.py::test_pool_scales_workers` imports
  stale in-process pool APIs (`QueueWorker`,
  `ScalableQueueWorkerPool`) that no longer exist on `noetl.worker`.
  Worker scale-up/down is now managed through Kubernetes/deployment
  controls and e2e/ops playbooks, so this tracked test needs retirement
  or replacement with a current autoscaling contract test.

Cluster-mode `live_vs_persisted_parity_smoke.py` was also tried
against the PFT execution `622020352981336195` and failed with
missing `rows`/`columns` paths. That smoke is designed for nested
control contracts such as agent diagnosis metadata; PFT terminal events
intentionally strip data-plane `rows`/`columns` from persisted result
context. Use spike/agent executions for cluster parity smoke, not the
PFT data-plane-heavy execution.
