# Handed travel Ollama Phase 4 to Codex (fourth provider via new mcp/ollama playbook)

- date: 2026-05-11T00:15:00Z
- tags: travel-agent, ollama, mcp-playbook, phase-4, in-cluster-bridge, codex-handoff

## Round goal

Final missing piece of the multi-provider travel arc: add Ollama as the
fourth AI provider, routed through a NEW `automation/agents/mcp/ollama`
NoETL playbook that wraps the in-cluster ollama-bridge service. Mirrors
Phase 3 (Vertex AI via MCP playbook) exactly.

## Architectural rationale

Today: openai + anthropic via urllib in classify_via_http_provider; vertex-ai
via mcp/vertex-ai playbook hop. Ollama was deferred because there was no
NoETL playbook wrapping the bridge — only a raw MCP server at
`http://ollama-bridge.noetl.svc.cluster.local:8765/jsonrpc`.

Two viable paths considered:

- **Option B (rejected)**: extend classify_via_http_provider with a third
  ollama urllib branch, posting JSON-RPC envelopes directly to the bridge.
  Smallest diff. But asymmetric with vertex-ai, and prevents future agents
  from reusing the Ollama integration via the canonical chat_completion
  contract.

- **Option A (chosen)**: create `automation/agents/mcp/ollama` as a NoETL
  playbook exposing the standard chat_completion MCP surface. Travel
  invokes via `tool: agent framework: noetl`. Symmetric with mcp/vertex-ai.
  "MCP is just a playbook" thesis applies a third time. Future agents (the
  troubleshoot agent already speaks chat_completion to mcp/ollama via raw
  HTTP) get a NoETL-native interface for free.

After this round, all four providers route through canonical interfaces:

| provider   | path                                              | rationale                              |
| ---------- | ------------------------------------------------- | -------------------------------------- |
| openai     | urllib in classify_via_http_provider              | trivial bearer auth                    |
| anthropic  | urllib in classify_via_http_provider              | trivial header auth                    |
| vertex-ai  | mcp/vertex-ai playbook hop                        | complex GCP auth chain                 |
| ollama     | mcp/ollama playbook hop (NEW)                     | in-cluster bridge wrapped canonically  |

## Stale port correction

Travel runtime workload had `ollama_bridge_url: "http://ollama-bridge...:8080"`.
This was always wrong — the bridge runs on 8765 (per troubleshoot/diagnose_execution.yaml
line 240's DEFAULT_OLLAMA_ENDPOINT). Phase 4 corrects it. The port has been
stale this whole time because the workload field was never used until now.

## New playbook shape

`automation/agents/mcp/ollama.yaml` mirrors vertex-ai.yaml structurally:
- One Python step that builds JSON-RPC envelope, POSTs via urllib to the
  bridge, parses MCP response, returns the standard chat_completion envelope.
- Output shape MATCHES mcp/vertex-ai byte-for-byte where possible — callers
  (the merger, plus future agents) don't need provider-specific code.
- Default model: `gemma3:4b` (matches troubleshoot agent default).
- Graceful 5xx via try/except urllib.error.HTTPError (Amadeus MCP pattern).

## Travel runtime changes

- Workload corrections (port + ollama_model + ai_provider comment).
- New classify_via_ollama_mcp step mirroring classify_via_vertex_mcp.
- start.next.arcs gains a fourth `when:` predicate.
- Merger extends to handle the ollama upstream (extract text, normalise,
  fall back to openai on isError or empty).
- All existing branch bodies (http, vertex) and merger paths are byte-for-byte
  preserved — only ADD the ollama path.

## Cap

1 ops PR (new playbook + travel runtime updates) + 1 docs PR.

## Phases (6)

1. Create mcp/ollama playbook (Pydantic-validate).
2. Wire travel runtime (Pydantic-validate).
3. Ops PR.
4. Docs PR.
5. Re-register + smoke five ollama intents + regressions + direct mcp/ollama call.
6. ai-meta pointer bumps. Stage but do not push.

## Bridge artefacts

- `bridge/inbox/delegated/20260511-001500-travel-ollama-via-mcp.task.json`
- `scripts/travel_ollama_via_mcp_msg.txt`

## Lurking design debt now load-bearing

After this round, the classifier system_prompt is DUPLICATED across THREE
branches (http Python const + vertex payload arg + ollama payload arg). The
hotels/activities round flagged this; Phase 4 makes it worse. This is real
coupling debt that will compound every time the schema extends (a future
new field — say `cabinClass` for premium-economy flights — requires editing
the prompt in three places).

A future architectural-purity round should extract the prompt into a single
workload field (or a tiny preamble step that emits it via output) referenced
by all three branches. NOT IN SCOPE for Phase 4 — but documented in result
file's deferred_followups so the next docs round can pin it.

Two NoETL-native ways to do the dedupe:
  1. Extract `workload.classifier_system_prompt: <multi-line YAML string>`
     and reference it from all three branches.
  2. Add a `prepare_classifier_prompt` step that emits `output.system_prompt`,
     and have the three classify_* branches read from it.

Option 1 is simpler. Option 2 is more flexible (the prompt could be assembled
from multiple inputs). Defer the choice to that round.

## What's next after this lands

7. Investigate Amadeus test API 500s on flights/locations
8. NoETL-Python globals/locals idiom into the authoring guide as 13th rule
9. Single-source-of-truth refactor for the classifier system_prompt
10. Anthropic re-smoke (gated on user; v2 task already on disk)

After Phase 4 closes GREEN, the architectural arc reaches its natural cap:
travel agent demonstrates four AI providers, four Amadeus tools, refinement
forms, audit trail, and three concrete examples of "MCP is just a playbook"
(Amadeus, Vertex AI, Ollama). The remaining items are polish, debt cleanup,
and external-dependency investigations rather than new architecture.
