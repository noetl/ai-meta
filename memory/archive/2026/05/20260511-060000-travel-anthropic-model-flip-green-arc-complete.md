# Travel Anthropic model flip closes GREEN — four-provider arc fully shipping

- date: 2026-05-11T06:00:00Z
- tags: travel-agent, anthropic, model-flip, green, arc-complete, four-providers-shipping

## What landed

- Ops PR: noetl/ops#68 — single-line model flip (b9f65ae)
- Travel runtime catalog 623844847958360223 v26
- Validation log appended: bridge/outbox/codex-spike-green-validation.md
- Screenshot proof: anthropic-flights-widget-selenium.png

## GREEN smoke evidence

- claude-haiku-4-5-20251001 returned 200 on the first probe (cost-optimal
  Haiku from Anthropic's May 2026 lineup — no need to drop to Sonnet 4)
- Five anthropic smokes (help/flights/locations/hotels/activities) all
  completed with `effective_provider='anthropic'`, no
  `provider_fallback_reason`
- Audit rows show `ai_provider='anthropic'` per smoke
- OpenAI default regression clean
- Vertex local-kind fallback remained expected (no WI on kind)

## Four-provider state — fully production-validated

| provider   | model                       | path                           |
| ---------- | --------------------------- | ------------------------------ |
| OpenAI     | gpt-4o-mini                 | urllib direct                  |
| Anthropic  | claude-haiku-4-5-20251001   | urllib direct                  |
| Vertex AI  | gemini-2.5-flash            | mcp/vertex-ai playbook hop     |
| Ollama     | gemma3:4b                   | mcp/ollama playbook hop        |

Three concrete examples of "MCP is just a playbook": Amadeus (Phase 2),
Vertex AI (Phase 3), Ollama (Phase 4). The thesis is fully load-bearing
in production.

## Arc complete — actionable deferred list cleared

Single user instruction ("one by one in order") drove this from the post-
Phase-4 cap through ten sequential rounds. Final state:

| round                                          | result                          |
| ---------------------------------------------- | ------------------------------- |
| 1  Workload-default rule (12th)                | GREEN                           |
| 2  Hotels/activities branches                  | GREEN                           |
| 3  app:form refinement widget                  | GREEN                           |
| 4  Audit side-effect inside render_*           | GREEN                           |
| 5a Anthropic re-smoke v2                       | AMBER → narrowed to model 404   |
| 5b Anthropic model flip                        | **GREEN (just now)**            |
| 6  Ollama Phase 4                              | GREEN                           |
| 7  Amadeus 500 investigation                   | GREEN (verdict b: sandbox)      |
| 8  Python globals/locals rule (13th)           | GREEN                           |
| 9  Classifier prompt single-source             | GREEN                           |

All ten actionable rounds shipped. The travel agent is feature-complete
as the NoETL-DSL-as-templating-library demo.

## What's actually left

Three deferred items remain, all are not blocking the arc:

1. **Path B — model-name workload-field refactor.** Anthropic + OpenAI
   model names are still hardcoded in classify_via_http_provider's Python
   helpers. Mirror the item #9 prompt single-source pattern: lift them
   into `workload.anthropic_model` and `workload.openai_model` (vertex
   and ollama models already are workload fields). Pure architectural-
   purity round — 1 ops PR. Optional.

2. **Activities NoETL-reference hydration bug.** Surfaced from item #7's
   investigation. Lives in repos/noetl engine code, OUTSIDE ops+docs
   scope. Affects all agent → MCP hops with large payloads. Needs a
   noetl-engine round when the user has bandwidth.

3. **Amadeus test API sandbox 500s.** Confirmed external (item #7
   verdict b). Friendly-error widget already handles gracefully. Future
   round if/when the user wants to switch to Amadeus production API.

## Session retrospective

This session's pattern was tight and worked well:
- User asks for next item.
- I write bridge task + Codex prompt + memory entry, surface the design
  trade-off in a single response.
- User pushes; Codex executes; user reports back.
- I write close-out memory; queue next round.

10 rounds shipped in one session without me writing any code directly —
the bridge handoff pattern is highly leveraged. Codex handles the
implementation, smokes, and in-flight regression patching; I handle the
design decisions and bookkeeping.

The longest-feedback-loop round (item #3, gui+ops+docs sequenced) still
fit the same pattern with explicit ordering constraints in the bridge
task. The shortest (model flip, this round) was end-to-end in under an
hour from problem identified to GREEN with screenshot.
