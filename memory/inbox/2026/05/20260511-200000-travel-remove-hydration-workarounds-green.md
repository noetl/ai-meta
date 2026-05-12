# Travel hydration workaround cleanup GREEN

Date: 2026-05-11

Post-v2.37.8 cleanup landed in `noetl/ops#71` (`82da6e559daeae1a27c034aa2bf18fb22dab0786`). The travel runtime no longer carries provider-specific child-event hydration helpers in the classifier merger:

- removed `_fetch_vertex_child_context`
- removed `_fetch_ollama_child_context`
- kept `_extract_vertex_text_from_context` and `_extract_ollama_text_from_context`, because they still normalize the chat-completion envelope shape
- replaced event-walking callers with direct `envelope.data` reads, falling back to the envelope itself only when `data` is not a dict

Validation:

- `Playbook.model_validate` passed for `automation/agents/travel/runtime.yaml`.
- Runtime line count dropped from `1894` to `1830` (`4 insertions`, `68 deletions`).
- Grep invariant is clean: both workaround names are absent.

Smokes:

| Surface | Command | Execution | Provider result | Render |
| --- | --- | --- | --- | --- |
| kind | `travel help` | `624806711404003707` | `openai` | `app:column` |
| kind | `travel --provider anthropic help` | `624806839179280848` | `anthropic` | `app:column` |
| kind | `travel --provider vertex-ai help` | `624806879100666405` | expected fallback to `openai`; hydrated `classify_via_vertex_mcp.data` present | `app:column` |
| kind | `travel --provider ollama help` | `624806944607306399` | `ollama`; hydrated `classify_via_ollama_mcp.data` present | `app:column` |
| GKE | `travel --provider vertex-ai help` | `624807547353956682` | `vertex-ai`; hydrated `classify_via_vertex_mcp.data` present | `app:column` |
| GKE | `travel --provider vertex-ai activities near Times Square` | `624807869216457156` | `vertex-ai`; hydrated Vertex classifier + Amadeus activities data | `app:column` |

The critical GKE activities regression proves the cleanup is safe: `classify_via_vertex_mcp.data` was hydrated by the engine, `amadeus_via_mcp_activities.data` carried `ok=true`, `items_len=10`, and `activities_total=1799`, and `render_activities` produced `10 activities found near (40.758, -73.9855)`.

Audit rows were present: kind wrote `classify_intent` rows for all four help smokes; GKE wrote `classify_intent` rows for both Vertex smokes and a `render_activities` row for `624807869216457156` with `render_type=app:column`.

ai-meta has the `repos/ops` pointer updated locally and staged, but not pushed. Result file: `bridge/outbox/20260511-200000-travel-remove-hydration-workarounds.result.json`.
