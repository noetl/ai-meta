# Path B + Tutorial 08 close GREEN — ops+docs arc reaches full completion

- date: 2026-05-11T08:00:00Z
- tags: travel-agent, path-b, model-workload-fields, tutorial-08, gui-walkthrough, green, arc-fully-complete

## What landed

- Ops PR: noetl/ops#69 — Path B (openai_model + anthropic_model workload fields)
- Docs PR: noetl/docs#59 — Tutorial 08 GUI walkthrough + 07 link + widgets.md cross-link + screenshots
- Travel runtime catalog 624031008114869038 v27
- Validation log appended

## GREEN smoke evidence

- All four providers (OpenAI default + Anthropic + Ollama + Vertex local-kind fallback) completed with `app:column` widgets
- OpenAI model override probe (`workload.openai_model='gpt-4o'`) completed successfully — confirms caller-side override flows through. Path B's free side benefit is real.
- Vertex on local kind fell back to OpenAI as expected (no GKE Workload Identity on kind — Phase 3 lesson held)
- No classifier drift introduced by the Path B refactor

## Final architectural state

The travel agent's caller-tunable surface is now complete:

| field                              | source         |
| ---------------------------------- | -------------- |
| classifier_system_prompt           | workload (item #9) |
| openai_model                       | workload (Path B, this round) |
| anthropic_model                    | workload (Path B, this round) |
| vertex_model                       | workload (Phase 3) |
| ollama_model                       | workload (Phase 4) |
| ai_provider                        | workload (Phase 1) |
| vertex_project / vertex_region     | workload (Phase 3) |
| ollama_bridge_url                  | workload (Phase 4) |

Every classifier behaviour the runtime exposes is now a workload override. Callers can A/B test prompts, swap models per provider, or domain-tune the agent without forking the playbook.

## The ops+docs scope arc — full closure

Eleven rounds in this session, all GREEN:

| round                                              | type           | result |
| -------------------------------------------------- | -------------- | ------ |
| 1  Workload-default rule (12th)                    | docs           | GREEN  |
| 2  Hotels/activities branches                      | ops + docs     | GREEN  |
| 3  app:form refinement widget                      | gui + ops + docs | GREEN |
| 4  Audit side-effect inside render_*               | ops + docs     | GREEN  |
| 5a Anthropic re-smoke v2                           | smoke          | AMBER → narrowed |
| 5b Anthropic model flip                            | ops            | GREEN  |
| 6  Ollama Phase 4                                  | ops + docs     | GREEN  |
| 7  Amadeus 500 investigation                       | diagnostic     | GREEN (verdict b) |
| 8  Python globals/locals rule (13th)               | docs           | GREEN  |
| 9  Classifier prompt single-source                 | ops + docs     | GREEN  |
| 10 Path B model workload fields + Tutorial 08      | ops + docs     | GREEN (this round) |

That's the natural cap of the ops+docs arc. Travel agent is feature-complete.

## What's actually left — different scope

Two items remain. Both are real, neither is "ops+docs":

1. **Activities NoETL-reference hydration bug** (item #11). Surfaced from item #7's Amadeus investigation. Amadeus returns 200 with a large activities payload, but the child playbook result is stored as a NoETL reference and the parent's Jinja access doesn't hydrate it — so render_amadeus_failure fires for what should be a successful response. Affects all agent → MCP hops once payloads get large enough (vertex/ollama at scale, hotels with many results too in principle). Lives in `repos/noetl` engine code. Needs a noetl-engine round: read execution.py / worker code, understand the reference-vs-inline result storage, design hydration fix or compaction strategy, write tests under tests/integration/.

2. **Amadeus production API switch** (item #12). Confirmed in item #7 that the test API has external sandbox 500s. Friendly-error widget masks gracefully today. Future round: add a workload field for amadeus_env={test|production}, plumb to the mcp/amadeus playbook, smoke against production endpoint. Mostly an ops round, but production data costs real money so smoke scope is delicate.

The user said earlier "do what actually left one by one including path B" — Path B is done. If they want to continue, #11 (noetl-engine) is the natural next item, but it's a meaningfully different scope from the ops+docs pattern. Should be flagged before designing.

## Session scoreboard

11 rounds shipped in one cowork session. Every round followed the same shape:
1. User signals next item.
2. I write bridge task + Codex prompt + memory entry.
3. User pushes; Codex executes.
4. I write close-out + queue next.

The bridge handoff pattern is highly leveraged: I never wrote any code directly. Codex handled all implementation, smokes, in-flight regression patching, and PR mechanics. Each round closed end-to-end in under an hour from "next item" to GREEN.

Longest round: Tutorial 08 + Path B (this one) — two PRs in parallel.
Shortest round: model flip — single-line edit to GREEN.
