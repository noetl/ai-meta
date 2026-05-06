---
date: 2026-05-06T04:27:12Z
title: Wrap-up GREEN — cluster restored, anchors fixed, ops docs landed; future note on Gemini/Vertex AI MCP for GKE
tags: [noetl, docs, cluster-restore, ollama-memory, replica-drift, vertex-ai, gemini, gke, future-direction, codex-bridge]
---

## Outcome

GREEN. Cluster restored to validated default state, two pre-existing
broken Docusaurus anchors fixed, both deferred MEDIUM doc gaps
closed in [noetl/docs#30](https://github.com/noetl/docs/pull/30).

Default spike execution `620538926150714099` GREEN with
`diagnosis_lookup.attempts=0`, source `ollama`. Confirms the
gemma3:4b path is fully validated again on v2.35.9.

## Two operational findings worth knowing

### 1. Ollama doesn't auto-reclaim memory after a failed model invocation

The initial gemma3:4b probe failed with:

```
Error: 500 Internal Server Error: model requires more system memory
(4.0 GiB) than is available (1.9 GiB)
```

This was AFTER the prior task's gemma4:e4b validation attempt. The
Ollama process was still holding gemma4:e4b's loaded weights even
though the inference call had errored out. Available memory in the
cgroup was 1.9 GiB instead of the expected ~4 GiB.

**Workaround**: `kubectl -n noetl rollout restart deploy/ollama`.
After the pod restarted, both models could load fresh and gemma3:4b
inference succeeded.

This is worth knowing because it means: **after any Ollama failure
involving a large model, expect to need a deployment restart to
reclaim memory.** Restart is fine — models stay on disk, no re-pull
needed.

Possible future improvement: add a startup probe to the Ollama
deployment that catches "stuck high resident memory" state and
auto-restarts. Or document it in `local-cluster.md` (which docs#30
just landed) as a troubleshooting note. Filing as a low-priority
follow-up.

### 2. noetl-worker replica drift between applied manifest and live state

The applied deployment manifest has `replicas: 3`. Live state
during this task showed `replicas: 1`. The nested spike child
execution stalled waiting for a free worker until Codex ran:

```
kubectl -n noetl scale deployment/noetl-worker --replicas=3
kubectl -n noetl rollout status deployment/noetl-worker --timeout=180s
```

Likely cause: the kind cluster recreate during yesterday's Podman
VM rebuild left the deployment at a default count below the
manifest's intent. The HPA (if any) didn't scale it back up because
load was zero at recreation time.

**Workaround**: `kubectl scale deployment/noetl-worker --replicas=3`
before the next session, or fold a `kubectl apply -f` of the noetl
manifests into the Podman/kind bootstrap script.

Worth folding into `docs/operations/local-cluster.md` as a
troubleshooting note for "spike execution stalls forever waiting on
worker."

## What landed in repos/docs

- [docs#30](https://github.com/noetl/docs/pull/30) merged at
  `a9c444e7a45d625274c2e112d0d8aafeee6de9e9`. Contains:
  - `docs/operations/bump_image.md` — closes T6 deferred gap. The
    GHCR availability probe, idempotent path, failure modes, worked
    example.
  - `docs/operations/local-cluster.md` — closes T13 deferred gap.
    Why Podman not Docker/Colima, `/Volumes:/Volumes` mount,
    `XDG_DATA_HOME` hygiene, sizing guidance citing the gemma4:e4b
    20 GiB cgroup measurement, optional LaunchAgent persistence
    pattern, bootstrap/recovery commands.
  - Two pre-existing broken anchors fixed:
    `self_troubleshoot_agent → mcp_catalog_architecture#metadata-fields`
    and `recreate-noetl-schema → noetl_cli_usage#database-management`.
- `npm install && npm run build` clean.

## Future direction: Gemini MCP / Vertex AI as cloud-managed alternative for GKE

Captured from user: when running NoETL on GKE Google Cloud, the
auto-troubleshoot diagnosis path should be able to use Google's
**Gemini API** or **Vertex AI** as the model backend INSTEAD of
running Ollama in-cluster. Playbooks should support switching
pointers — same diagnose_execution contract, different upstream.

This maps cleanly to the existing MCP-as-playbook pattern (Gap 2 /
noetl#405). The pointer that needs swapping is
`workload.ollama_mcp_server`:

```yaml
# Today (in-cluster Ollama):
workload:
  ollama_mcp_server: "mcp/ollama"
  ollama_model: "gemma3:4b"

# Future (Vertex AI on GKE):
workload:
  ollama_mcp_server: "mcp/vertex-ai"   # or "mcp/gemini"
  ollama_model: "gemini-2.0-flash"     # name flow through the same axis
```

The auto-troubleshoot agent's MCP-call layer is already abstracted
enough that this should "just work" given:

1. A `mcp/vertex-ai` (or `mcp/gemini`) playbook in repos/ops with
   the same JSON-RPC tools/list + tools/call contract as
   `mcp/ollama`, proxying to Vertex AI / Gemini APIs.
2. Catalog registration so the playbook is invocable.
3. Workload knobs for cloud credentials: `vertex_credential`,
   `vertex_project`, `vertex_region` (or equivalent for Gemini API
   keys, with the standard NoETL credential pattern).
4. Model-name mapping documented somewhere — e.g. gemma3:4b's local
   role maps to gemini-2.0-flash; qwen3:32b's escalation role maps
   to gemini-2.0-pro. Or the operator picks per-deployment.
5. `docs/architecture/triage_model_selection.md` extended with a
   "Deployment mode: in-cluster Ollama vs cloud-managed Vertex /
   Gemini" section, including the credential model and the
   per-mode tradeoffs (latency, cost, data residency).

Open design questions for when this becomes work:

- **Naming**: should the workload field stay `ollama_mcp_server`
  with implicit-pointer semantics, or rename to
  `triage_mcp_server` to signal that any compatible MCP backend is
  valid? Probably the latter — clearer separation between "which
  MCP backend" and "which model on that backend."
- **Credential surface**: Vertex AI uses Workload Identity / GKE
  metadata server; Gemini API uses an API key. Two different
  credential patterns. The MCP playbook should encapsulate both
  behind the same interface so the troubleshoot agent doesn't
  branch on backend type.
- **Discriminated default**: should `diagnose_execution.yaml`
  detect deployment context (e.g. `KUBERNETES_SERVICE_HOST` +
  cloud-provider env vars) and pick a default automatically? Or
  always require explicit operator override? Probably explicit —
  defaults that change by environment are a debugging nightmare.

This is a substantial design pass plus a real implementation
effort (estimating: 1 ops PR for the new MCP playbook, 1 noetl
PR if the agent-side abstraction needs work, 1 docs PR).
**Filed for later**, not blocking anything currently shipping.

## Submodule pointer (committed locally in ai-meta, awaiting push)

```
repos/docs   a9c444e7a45d625274c2e112d0d8aafeee6de9e9   (post-#30)
```

ai-meta `main` is 1 commit ahead of origin:

```
b9e53d4 chore(sync): bump repos/docs for bump_image + local-cluster operations docs
```

## Refs

- bridge/outbox/20260506-040838-cluster-restore-anchors-deferred-mediums.result.json
- noetl/docs#30 (operations docs + anchor fixes)
- repos/docs/docs/operations/bump_image.md (new)
- repos/docs/docs/operations/local-cluster.md (new)
- bridge/outbox/docs_coverage_audit.md (canonical audit; T6 + T13
  now COVERED)
