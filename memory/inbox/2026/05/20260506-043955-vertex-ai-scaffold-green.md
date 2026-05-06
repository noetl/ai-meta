---
date: 2026-05-06T05:08:39Z
title: Vertex AI / Gemini MCP scaffold GREEN — pointer-swap proven via stub backend
tags: [noetl, vertex-ai, gemini, mcp, pointer-swap, stub, scaffolding, codex-bridge, future-direction]
---

## Outcome

GREEN. The pointer-swap architecture is proven end-to-end with a
stub MCP backend. Real Vertex AI / Gemini API integration is the
next step — design + scaffolding land first, cloud calls follow.
Cluster remains on `v2.35.9`, catalog defaults unchanged
(`mcp/ollama` + `gemma3:4b` stay validated).

## Three PRs landed (1 over cap, justified)

- **[noetl/docs#31](https://github.com/noetl/docs/pull/31)** —
  `docs/architecture/vertex_ai_triage_backend.md`. All 9 required
  sections present: pointer-swap rationale, MCP contract, naming
  convention, model name flow-through, credential surface
  unification, discriminated default policy, cost telemetry, no
  streaming, migration path. `npm run build` clean.
- **[noetl/ops#39](https://github.com/noetl/ops/pull/39)** —
  combined: new `automation/agents/mcp/vertex-ai-stub.yaml` (canned
  JSON-RPC `chat_completion` returning all 5 diagnosis keys with
  `source: "vertex-stub"` and mock token usage); diagnose_execution
  rename adding `triage_mcp_server` / `triage_model` as canonical
  fields with `ollama_*` deprecated aliases.
- **[noetl/e2e#9](https://github.com/noetl/e2e/pull/9)** — spike
  fixture compatibility shim (over the original 2-PR cap, but
  unavoidable — see "v2.35.9 worker key-forwarding finding" below).

## The architectural finding worth knowing

**The v2.35.9 worker only forwards `ollama_*` keys, not all
workload keys.** When the spike fixture passed `triage_mcp_server`
+ `triage_model` to the on_failure hook, those keys did not
propagate to the diagnose sub-execution's render context. To make
the new-field spike actually work end-to-end, the spike fixture
had to **mirror values into both `triage_*` AND `ollama_*` fields**
in the on_failure block:

```yaml
# repos/e2e/fixtures/playbooks/spike/spike_e2e_test.yaml (post-#9)
on_failure:
  troubleshoot: true
  triage_mcp_server: "{{ workload.triage_mcp_server }}"
  triage_model:      "{{ workload.triage_model }}"
  # Compat shim for v2.35.9-era workers: mirror to ollama_* alias
  ollama_mcp_server: "{{ workload.triage_mcp_server }}"
  ollama_model:      "{{ workload.triage_model }}"
```

The proof of this is in the result file's `swap_field_paths` — at
`events.26.context.tool_config.on_failure`, BOTH `ollama_model`
and `triage_model` carry `gemini-2.0-flash`. Without the mirror,
only one of those keys would have been populated and the value
would have failed to reach the diagnose render context.

This is a real noetl follow-up: **the worker's
workload-forwarding logic should pass through all keys generically,
not be aware of specific key names**. Filed as a deferred follow-up
in the result file. Not blocking — the alias mirror works for
v2.35.9 — but worth fixing in the next noetl release so future
fixtures don't need to know about old key names.

## Pointer-swap evidence (canonical)

Three execution_ids prove the swap works:

```
baseline (default Ollama):  620561855144001654
  → diagnosis.source = "ollama"
  → diagnosis.model  = "gemma3:4b"

new-fields → stub:          620562183952269599
  → diagnosis.source = "vertex-stub"
  → diagnosis.model  = "gemini-2.0-flash"

old-fields alias → stub:    620562495555502573
  → diagnosis.source = "vertex-stub"
  → diagnosis.model  = "gemini-2.0-flash"
```

The result file captures 30+ field paths showing exactly which
event_id × field_path × value chains carry the model and source
through extract_envelope, trigger_failure terminal events, and
the on_failure render context. That's the canonical proof for
future regression checks.

## All 5 smokes pass

Carveout 8/8, gap41_wait 7/7, auto_troubleshoot 9/9, optional_ai
6/6, parity static 2/2. The carve-outs and projection contracts
weren't touched in this round, so this was the expected baseline.

## Submodule pointers (committed locally in ai-meta, awaiting push)

```
repos/docs   987e69e0b728ceb6546dd0453513c9efb90ed2d7   (post-#31)
repos/ops    770527a5b74694afbc619a1d075e973fbe84eecf   (post-#39)
repos/e2e    699e3d9af344340b2b81ebd1970e570eebffc451   (post-#9)
```

ai-meta `main` is 1 commit ahead of origin:

```
c0da0ed chore(sync): bump docs, ops, e2e for Vertex triage stub
```

## Three deferred follow-ups (in priority order)

1. **Real Vertex AI / Gemini API integration replacing the stub
   backend.** The big one — drop in actual Google Cloud calls
   behind the same JSON-RPC contract the stub validated.
   `repos/ops/automation/agents/mcp/vertex-ai.yaml` (no `-stub`
   suffix). Credential surface: Workload Identity for GKE,
   API-key fallback for Gemini API. Requires a real GKE
   cluster for end-to-end validation.

2. **Worker key-forwarding generalisation.** Today the v2.35.9
   worker forwards `ollama_*` keys specifically. Should forward
   all workload keys generically so future fixtures don't need
   to know about old key names. Noetl change. Land before
   removing the alias in step 3.

3. **Remove deprecated `ollama_mcp_server` / `ollama_model`
   aliases.** After step 2 lands and any consumers have migrated
   to `triage_*`. Single ops PR. Bumps a release as a breaking
   change for any operators who haven't migrated.

## What this round didn't change

- Catalog defaults: `mcp/ollama` + `gemma3:4b` still the validated
  default.
- Ollama resources: `requests=3Gi, limits=5Gi` (post-ops#38).
- Cluster state: still v2.35.9 across server / worker /
  ollama-bridge.
- No noetl release.
- No cloud calls — stub-only this round.

## Refs

- bridge/outbox/20260506-043955-vertex-ai-design-and-stub-pointer-swap.result.json
- sync/issues/2026-05-06-future-vertex-ai-gemini-mcp-pointer-swap.md
- noetl/docs#31, noetl/ops#39, noetl/e2e#9
- repos/docs/docs/architecture/vertex_ai_triage_backend.md
- repos/ops/automation/agents/mcp/vertex-ai-stub.yaml
- repos/ops/automation/agents/troubleshoot/diagnose_execution.yaml
  (renamed fields + aliases)
- repos/e2e/fixtures/playbooks/spike/spike_e2e_test.yaml (compat
  shim for v2.35.9 worker key-forwarding)
