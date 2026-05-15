---
date: 2026-05-06T15:49:00Z
title: GKE Vertex AI thread CLOSED — production-validated, honest cloud-latency docs, future-work captured
tags: [noetl, gke, vertex-ai, gemini-2.5-flash, retrospective, arc-close, codex-bridge]
---

## Outcome

GREEN. The GKE Vertex AI thread is fully closed. Final docs PR
[noetl/docs#34](https://github.com/noetl/docs/pull/34) merged.
Sync issue captured for future noetl retry-budget tuning.
Validation log appended with honest empirical findings.

## What this close-out round shipped

- **docs#34**: cloud-latency variance documented across three
  architecture pages — `triage_model_selection.md`,
  `vertex_ai_triage_backend.md`,
  `agent_failure_diagnostics.md`. Operators now know to expect
  `attempts == 0` typical / `attempts == 1` occasional for local
  Ollama, and `attempts == 0..3` typical / up to ~5 acceptable
  for cloud Vertex AI. Anything above the per-backend threshold
  is a regression signal.
- **`sync/issues/2026-05-06-noetl-retry-budget-cloud-aware.md`**:
  the proper noetl-side fix captured for future work — make
  `_fetch_persisted_diagnosis_from_doc`'s retry budget
  backend-aware (or just longer unconditionally) so cloud
  backends don't rely on the spike fixture's belt-and-suspenders
  poll. Three architectural options laid out with effort
  estimates.
- **Validation log paragraph appended** to
  `bridge/outbox/codex-spike-green-validation.md` with honest
  evidence: 6/6 GKE runs functionally GREEN with
  `source=vertex-ai`, `model=gemini-2.5-flash`; 4/6 hit
  `attempts ≤ 1`, 2/6 hit `attempts 2-3` per the documented
  cloud-latency variance.

## Multi-day arc retrospective

Started at v2.35.1 with a RED spike e2e. Six bridge rounds across
~36 hours produced:

**Releases shipped**: v2.35.3 → v2.35.4 → v2.35.5 → v2.35.6 →
v2.35.7 → v2.35.8 → v2.35.9. Six NoETL releases. Final
production-validated tag: v2.35.9.

**PRs across all repos** (~21 total):
- `noetl`: #412 (envelope wait), #413 (Gap 4.1 wait+fetch),
  #414 (stateless MCP), #415 (inferred-fallback), #416 (retry
  race), #417 (event projection)
- `ops`: #35 (POSIX bump_image), #36 (Ollama MCP endpoint),
  #37 (GHCR probe), #38 (Ollama 5Gi), #39 (vertex stub +
  rename), #40 (real vertex-ai), #41 (vertex helper fixes)
- `e2e`: #8 (poll workaround), #9 (compat shim)
- `docs`: #27 (parity smoke section), #28 (triage model
  selection), #29 (failure diagnostics contract), #30 (ops
  reference), #31 (vertex backend design), #32 (frontend
  quickstart), #33 (gemini-2.5-flash reconciliation), #34
  (cloud-latency variance)

**Architectural fixed-points reached**:
- Agent envelope is the contract: both `tool: agent` step and
  the auto-troubleshoot hook wait for sub-execution terminal
  status before reading, with retry on the events-flush race.
- The persisted event stream and the live response agree on
  nested-dict shape; `_extract_control_context()` is the single
  chokepoint with one explicit carve-out (`error.diagnosis`)
  and a parity smoke that catches future regressions at
  PR-time.
- Deploys go through `bump_image` with a GHCR-availability
  probe so release races fail fast instead of timing out
  kubectl rollouts.
- MCP servers handle stateless JSON-RPC.
- The four kinds carrying nested dicts (`agent`,
  `task_sequence`, `mcp`, `playbook`) all have documented
  projection paths.
- **Deployment-mode-aware MCP routing in production**: local
  kind uses `mcp/ollama` (gemma3:4b); GKE uses `mcp/vertex-ai`
  (gemini-2.5-flash) + `mcp/gcp/gke` for cluster
  observability. Same JSON-RPC contract, same diagnose envelope
  shape, different upstream backend.

**Five regression smokes** built and validated:
`agent_envelope_carveout` (8/8), `gap41_diagnosis_wait` (7/7),
`auto_troubleshoot` (9/9), `optional_ai` (6/6),
`live_vs_persisted_parity` (2/2 static + cluster mode).

**GKE production state**:
- Cluster: `noetl-cluster` in `us-central1`, project
  `noetl-demo-19700101`.
- noetl-server / noetl-worker on `ghcr.io/noetl/noetl:v2.35.9`.
- gateway on `ghcr.io/noetl/gateway:v2.10.0` at
  `https://gateway.mestumre.dev`.
- gui on `ghcr.io/noetl/gui:v1.7.0` at `https://mestumre.dev`.
- Workload Identity → Vertex AI confirmed; token telemetry
  captured in `_meta.usage`.
- mcp/gcp/gke responding with 15 cluster observability tools.

**Documentation surface closed** (audit at
`bridge/outbox/docs_coverage_audit.md`): 13 topics audited at
the start of the docs round; after this arc, the HIGH gaps are
all closed and the MEDIUM gaps have either been filled or
filed as future work.

**Future-direction notes captured for the next thread**:
- `sync/issues/2026-05-06-future-vertex-ai-gemini-mcp-pointer-swap.md`
  → real Vertex AI integration (DONE this arc).
- `sync/issues/2026-05-06-noetl-retry-budget-cloud-aware.md`
  → noetl retry budget tuning for cloud-managed backends.
- Worker key-forwarding generalisation (deferred from ops#39).
- Remove deprecated `ollama_mcp_server` / `ollama_model`
  aliases after a release cycle.

## What's staged in ai-meta (awaiting push)

```
M  bridge/outbox/codex-spike-green-validation.md   (validation log append)
M  repos/docs                                      (#33 + #34 pointer bump)
A  sync/issues/2026-05-06-noetl-retry-budget-cloud-aware.md
?? bridge/outbox/20260506-153850-cloud-latency-close-out.result.json
```

The result file at `bridge/outbox/20260506-153850-cloud-latency-close-out.result.json`
needs adding too.

## Refs

- bridge/outbox/codex-spike-green-validation.md (the canonical
  arc validation log — multiple paragraph entries documenting
  RED → AMBER → GREEN → AMBER (regression, fixed) → GREEN →
  AMBER (model availability) → GREEN (close-out))
- noetl/docs#34
- sync/issues/2026-05-06-noetl-retry-budget-cloud-aware.md
- All prior memory entries in
  `memory/inbox/2026/05/20260505-*` and
  `memory/inbox/2026/05/20260506-*` document the round-by-round
  progression.
