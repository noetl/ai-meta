---
date: 2026-05-06T21:13:00Z
title: Round 2 GREEN — deprecated ollama_* aliases removed; canonical triage_* is the only input now
tags: [noetl, ops, alias-removal, deprecation, codex-bridge, follow-up-round-2-of-3]
---

## Outcome

GREEN. Round 2 of 3 done. Deprecated `ollama_mcp_server` /
`ollama_model` workload aliases removed from three files in
`repos/ops/automation/agents/troubleshoot/`. The canonical
`triage_*` fields are now the only documented input names.

## What landed

- **[noetl/ops#42](https://github.com/noetl/ops/pull/42)** merged
  at `690bf23`. Removed alias references from
  `diagnose_execution.yaml`, `runtime.yaml`, and `README.md`.
- **Catalog re-registered** with new versions:
  - Local: diagnose_execution v14
  - GKE: diagnose_execution v3
- **Validation log** appended documenting the alias removal.

## 3-run GKE validation

```
canonical triage payload:  621076778177527989  vertex-ai / gemini-2.5-flash  attempts=0
bare payload (defaults):   621077111373037955  ollama / gemma3:4b           attempts=0
legacy ollama_* payload:   621077418630971948  ollama / gemma3:4b           attempts=0
                                               (graceful degradation confirmed)
```

All 3 GREEN, all `attempts=0`. The legacy ollama_* payload is
silently ignored — the playbook no longer reads those fields, so
the spike falls through to GKE catalog defaults and runs cleanly.
This is the documented "graceful degradation" for a deprecation
cycle that has run its course.

## All six smokes pass

Including the new `worker_workload_forwarding_smoke.py` from
round 1. The smoke suite is now:

1. agent_envelope_carveout — 8/8
2. gap41_diagnosis_wait — 7/7
3. auto_troubleshoot — 9/9
4. optional_ai — 6/6
5. live_vs_persisted_parity — 2/2 static
6. worker_workload_forwarding — passing

## Architectural fact I had wrong in the task spec

I wrote the task expecting bare/legacy GKE payloads to fall
through to **vertex-ai** defaults. They actually fall through to
**ollama** defaults — because the GKE catalog defaults are still
`mcp/ollama` / `gemma3:4b`, identical to local kind. This was the
deliberate choice from the prior GKE wire-up task ("pattern b":
keep catalog defaults source-of-truth uniform; GKE operators pass
explicit `triage_mcp_server: mcp/vertex-ai` per payload).

Codex flagged the discrepancy correctly. The validation still
proved the alias-removal point (graceful degradation), just with
ollama as the fallback rather than vertex. Both are valid
fallback semantics; the test still GREENed.

This is worth keeping in mind for the round 3 task spec: **don't
assume GKE catalog defaults are vertex-flavored just because GKE
deployments typically use vertex.** The deployment-mode-aware
backend choice happens at the workload-payload level, not the
catalog-defaults level. That's the operator-explicit pattern we
chose.

## The dispatch chain is now canonical-only end to end

Before this round:
- Worker forwarding: name-agnostic (since v2.36.0 / round 1)
- Diagnose dispatcher: name-agnostic (since v2.35.5)
- Playbook input resolution: had alias support
  (`triage_* > ollama_* > default`)

After this round:
- Worker forwarding: name-agnostic ✓
- Diagnose dispatcher: name-agnostic ✓
- Playbook input resolution: **canonical-only** (just
  `triage_* > default`) ✓

The deprecation cycle is complete. The only remaining round-3
item — retry-budget cloud-aware tuning — is independent of the
naming surface and tackles the cloud-latency variance documented
in the prior arc.

## Submodule pointer (committed locally in ai-meta, awaiting push)

```
M  bridge/outbox/codex-spike-green-validation.md  (validation log append)
M  repos/ops                                      (ops#42 → 690bf23)
```

## Refs

- bridge/outbox/20260506-213402-remove-deprecated-ollama-aliases.result.json
- noetl/ops#42
- bridge/outbox/codex-spike-green-validation.md (validation log
  with new alias-removal entry)
- sync/issues/2026-05-06-noetl-retry-budget-cloud-aware.md (round 3,
  the last open follow-up)
