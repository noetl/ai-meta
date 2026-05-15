---
date: 2026-05-06T16:31:00Z
title: Worker key-forwarding generalisation GREEN — v2.36.0 ships, spike compat mirror dropped
tags: [noetl, worker, key-forwarding, v2.36.0, e2e, codex-bridge, follow-up-round-1-of-3]
---

## Outcome

GREEN. The v2.35.9 worker's name-aware filter that only forwarded
`ollama_*` keys is now generalised — `triage_*` (and other
documented workload knobs) propagate through `on_failure` to
sub-execution render contexts without compat mirrors. Released as
**v2.36.0** (semantic-release picked the minor bump because the
PR was `feat(worker)` — correct semver behavior; the task spec
optimistically anticipated v2.35.10 but the minor bump is right).

## What landed

- **[noetl/noetl#418](https://github.com/noetl/noetl/pull/418)** —
  worker key-forwarding generalisation. Released as
  `ghcr.io/noetl/noetl:v2.36.0`. Deployed to GKE noetl-server
  + noetl-worker via the `bump_image` lifecycle agent.
- **[noetl/e2e#10](https://github.com/noetl/e2e/pull/10)** — spike
  fixture's `triage_* → ollama_*` compat mirror dropped. Spike now
  passes only the canonical `triage_*` keys in `on_failure`. Spike
  catalog version: 3.
- **`scripts/worker_workload_forwarding_smoke.py`** — new smoke
  staged. Exercises the generalised forwarding without any
  compat mirror; passes against v2.36.0.
- **`scripts/spike_e2e_assert.py`** — added `vertex-ai` to the
  `valid_sources` allowed list. The list already had `vertex-stub`
  from the earlier round but was missing `vertex-ai`. Codex
  flagged this as a freshness issue during validation; one-line
  fix folded into this round's wrap-up.

## 3-run GKE evidence (triage-only payload, no compat mirror)

```
620994605177111106: vertex-ai, gemini-2.5-flash, attempts=0
620995237736874768: vertex-ai, gemini-2.5-flash, attempts=0
620995649835631584: vertex-ai, gemini-2.5-flash, attempts=3
```

2/3 hit `attempts=0`, 1/3 at `attempts=3` — within the documented
cloud-latency variance profile (attempts 0..3 typical for cloud
backends per `vertex_ai_triage_backend.md`'s cloud-latency
section). The next round's retry-budget tuning should bring the
2/3 case down to attempts ≤ 1.

## Architectural significance

The worker's workload-forwarding path was the last name-aware
component in the agent dispatch chain. Now:

- Diagnose dispatcher: name-agnostic (since v2.35.5).
- Worker forwarding: name-agnostic (this round).
- Playbook input resolution: still has alias support
  (`triage_* > ollama_* > default`) — gets removed in the next
  round.

After alias removal lands, the entire path is canonical-only.
After retry-budget tuning lands, cloud-latency variance is
absorbed at the noetl side and the spike fixture's polling loop
becomes pure regression detector with no real role.

## Submodule pointers (committed locally in ai-meta, awaiting push)

```
M  bridge/outbox/codex-spike-green-validation.md  (validation log append)
M  repos/e2e                                      (e2e#10)
M  repos/noetl                                    (noetl#418)
A  scripts/worker_workload_forwarding_smoke.py    (new smoke)
M  scripts/spike_e2e_assert.py                    (vertex-ai added to valid_sources)
```

## Next two rounds in this thread

1. **Alias removal** (next): drop `workload.ollama_mcp_server` and
   `workload.ollama_model` from `diagnose_execution.yaml`. Now safe
   because triage_* propagates without the alias. Single ops PR.
2. **Retry-budget cloud-aware tuning**: tune
   `_fetch_persisted_diagnosis_from_doc`'s retry budget for cloud
   backend latency. Should bring the 1/3 attempts=3 case down to
   attempts ≤ 1. Single noetl PR + release + redeploy.

Both follow-ups depend on this worker fix landing first — done.

## Refs

- bridge/outbox/20260506-163551-worker-key-forwarding-generalisation.result.json
- noetl/noetl#418, noetl/e2e#10
- sync/issues/2026-05-06-noetl-retry-budget-cloud-aware.md (round 3)
- bridge/outbox/codex-spike-green-validation.md (validation log
  with new v2.36.0 entry)
