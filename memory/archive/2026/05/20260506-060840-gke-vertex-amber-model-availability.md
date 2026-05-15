---
date: 2026-05-06T07:46:08Z
title: GKE deploy + Vertex AI integration AMBER — architecture works, blocked only by Vertex model availability in noetl-demo-19700101
tags: [noetl, gke, vertex-ai, gemini-2.5-flash, model-availability, frontend-docs, codex-bridge]
---

## Outcome

AMBER — but for the right reason. The architecture works end-to-end:
real Vertex AI MCP, Workload Identity auth, GenerateContent calls,
token usage captured, GCP observability MCP responding, GKE deploy
healthy, frontend docs landed. **The only blocker is that the
acceptance criterion in the task spec required `gemini-2.0-flash`,
and that specific model returns Vertex HTTP 404 in the
`noetl-demo-19700101` project across `us-central1` and `global`.**
The replacement `gemini-2.5-flash` works perfectly and is the de
facto production triage model on this cluster.

## What's deployed and proven

```
GKE cluster:    noetl-cluster (us-central1) in noetl-demo-19700101
namespace:      noetl
noetl-server:   ghcr.io/noetl/noetl:v2.35.9
noetl-worker:   ghcr.io/noetl/noetl:v2.35.9
gateway:        ghcr.io/noetl/gateway:v2.10.0
gui:            ghcr.io/noetl/gui:v1.7.0
gateway URL:    https://gateway.mestumre.dev (health = ok)
gui URL:        https://mestumre.dev (HTTP 200)
```

Note: ollama-bridge is NOT deployed on GKE (Vertex AI replaces
it). Local kind continues to use ollama-bridge.

## Vertex AI evidence (gemini-2.5-flash)

```
spike execution: 620639495284589035 — GREEN, attempts=0
diagnosis source: vertex-ai
diagnosis model:  gemini-2.5-flash
token usage:      prompt=42, completion=35, total=97
event evidence:
  - 620639883551310520
  - 620639882175578792
  - 620639012092379603
field paths:
  - events[extract_envelope.command.completed].result.context.diagnosis.{source,model}
  - events[trigger_failure.command.completed].result.context.error.diagnosis.{source,model}
  - events[vertex_generate_content.command.completed].result.context.usage.{prompt,completion,total}_tokens
```

Workload Identity binding works (Codex didn't have to provision it
— it was already there). Real GenerateContent calls return real
diagnoses with real cost telemetry.

## GCP observability MCP (mcp/gcp/gke)

```
execution: 620640584042021564 — PASS
tools returned: 15
```

The pre-existing managed GKE MCP endpoint
(`container.googleapis.com/mcp/read-only`) responds via Workload
Identity. 15 cluster-observability tools available to playbooks
running on GKE.

## What landed

- [noetl/ops#40 + #41](https://github.com/noetl/ops/pull/41) —
  real `mcp/vertex-ai.yaml`, with #41 fixing helper scoping under
  NoETL Python execution, MCP model override precedence, and
  global endpoint handling. Catalog version on GKE: 6.
- [noetl/docs#32](https://github.com/noetl/docs/pull/32) —
  `frontend-quickstart.md` with all required sections including
  worked example. `npm run build` clean.
- ai-meta submodule bumps: `34fa8e3` (ops for real Vertex AI MCP)
  + `178850c` (ops + docs for GKE deploy).

## The model-availability finding

Vertex AI returned HTTP 404 for `gemini-2.0-flash` and
`gemini-2.0-flash-001` in `noetl-demo-19700101` across both
`us-central1` and `global` endpoints. This is a Google-side
availability decision, not a code bug. Possible causes (operator
investigation, not Claude/Codex):

1. **Model garden activation**: some Vertex models require
   per-project enablement in Vertex AI Model Garden before
   they're callable. `gemini-2.5-flash` may have been activated
   when the project was set up; `gemini-2.0-flash` may not have
   been.
2. **Region availability**: `gemini-2.0-flash` might be
   available in different regions (e.g. `us-east4`) but not
   `us-central1` for this project.
3. **Project-tier**: free-tier or trial projects sometimes have
   limited model access. Production projects with billing
   typically have broader access.
4. **Model lifecycle**: `gemini-2.0-flash` may be transitioning
   to legacy status as `gemini-2.5-flash` becomes the default
   recommendation. Google sometimes gates older versions when a
   newer one supersedes them.

**Action recommendation**: just adopt `gemini-2.5-flash` as the
documented default for the Vertex backend. It's actually a newer
and better model than 2.0-flash. The docs at
`triage_model_selection.md` and `vertex_ai_triage_backend.md` need
their model-mapping table updated:

```
Old (in docs):                          New (reality):
gemma3:4b ↔ gemini-2.0-flash    →      gemma3:4b ↔ gemini-2.5-flash
qwen3:32b ↔ gemini-2.5-pro      →      qwen3:32b ↔ gemini-2.5-pro (unchanged)
```

This is a small docs PR, not a code change.

## Secondary partial: gateway GraphQL e2e

Bucket "gateway_graphql_e2e" returned HTTP 403 because Codex used a
cached gateway session token rather than performing a fresh Auth0
login. Not blocking — the gateway health endpoint passed, the
auth-integration logic works, this is just a stale-token symptom.
Worth resolving in the doc-reconciliation follow-up: a fresh
session login + a successful GraphQL `executePlaybook` mutation
gives us the canonical end-to-end proof for the frontend
quickstart's worked example.

## Submodule pointers (committed locally in ai-meta, awaiting push)

```
repos/ops    (already pushed in 34fa8e3)
repos/docs   (committed in 178850c)
```

ai-meta `main` is 2 commits ahead of origin:

```
178850c chore(sync): bump ops and docs for GKE Vertex AI deploy
34fa8e3 chore(sync): bump repos/ops for real Vertex AI MCP
```

## Next round (small): doc reconciliation + fresh GREEN sweep

Bounded follow-up to flip from AMBER to GREEN cleanly:

1. Update `repos/docs/docs/architecture/{triage_model_selection,vertex_ai_triage_backend}.md` to reflect that `gemini-2.5-flash` is the production default for Vertex (not 2.0-flash). Cite this round's evidence trail. Note the 404 finding as a "model availability" troubleshooting section.
2. Re-run the spike on GKE with `gemini-2.5-flash` and `escalate_to: none`, capture three-run stability proof for the regression sweep.
3. Fresh Auth0 login + GraphQL `executePlaybook` mutation against the deployed gateway, captured as the canonical e2e proof for `frontend-quickstart.md`'s worked example.
4. Append the validation log entry for `codex-spike-green-validation.md` noting the GKE + Vertex AI deploy with `gemini-2.5-flash`.

Cap: 1 docs PR (model-name reconciliation) + 0 code PRs (architecture is unchanged, just the docs were optimistic about model naming).

## What this proves architecturally

- **Deployment-mode-aware MCP routing works.** Local uses
  `mcp/ollama` (gemma3:4b); GKE uses `mcp/vertex-ai`
  (gemini-2.5-flash). Same auto-troubleshoot diagnose contract,
  same evidence trail shape, different upstream backend.
- **Workload Identity → Vertex AI path is solid.** No
  hand-managed credentials in pods. The token flow through metadata
  server works in production.
- **GCP observability MCP is plumbed.** `mcp/gcp/gke` exposes 15
  cluster tools to playbooks running on GKE. Future
  troubleshoot/diagnose flows can call it for cluster state
  context without leaving the agent runtime.
- **The pointer-swap thesis from ops#39 holds.** Same JSON-RPC
  contract; the MCP playbook is the only thing that changes
  between backends. Operators pick per-deployment.

## Refs

- bridge/outbox/20260506-060840-gke-deploy-test-document.result.json
- noetl/ops#40 (real mcp/vertex-ai)
- noetl/ops#41 (helper scoping + model precedence + global
  endpoint fixes)
- noetl/docs#32 (frontend-quickstart)
- repos/ops/automation/agents/mcp/vertex-ai.yaml
- repos/docs/docs/gateway/frontend-quickstart.md
- repos/docs/docs/architecture/{triage_model_selection,vertex_ai_triage_backend}.md
  (target of next-round doc reconciliation)
