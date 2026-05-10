# Handed classifier prompt single-source refactor to Codex (load-bearing debt cleanup)

- date: 2026-05-11T03:50:00Z
- tags: travel-agent, classifier, system-prompt, single-source-of-truth, refactor, codex-handoff

## Round goal

Dedupe the classifier system_prompt across the three classify_via_* branches
into a single workload field. Resolves the load-bearing debt flagged after
the hotels/activities round and promoted to "no longer optional" after Phase 4.

## The duplication

| location                                | shape                                      |
| --------------------------------------- | ------------------------------------------ |
| classify_via_http_provider              | Python `system_prompt` constant            |
| classify_via_vertex_mcp                 | payload.arguments.system inline string     |
| classify_via_ollama_mcp                 | payload.arguments.system inline string     |

Three places. Every schema extension (cityCode in hotels round, latitude/
longitude for activities) has touched all three. One drift would cause
provider-dependent classification — the merger normalises shape but can't
recover semantic differences.

## Option chosen

Two paths considered in the Phase 4 close-out memo:

1. **Workload field (chosen)**: lift the prompt into
   `workload.classifier_system_prompt` as a `|` literal block scalar.
   Three branches each reference `"{{ workload.classifier_system_prompt }}"`.
   Static metadata, no runtime composition, simpler diff.

2. **Preamble step**: add a tiny `prepare_classifier_prompt` step that
   emits `output.system_prompt`, three branches read from it. More
   flexible (could compose the prompt from multiple workload inputs),
   but adds a step for no current benefit.

Option 1 wins on simplicity. Free side benefit: callers can override the
prompt via workload for A/B testing or domain-specific tuning without
forking the runtime.

## Byte-for-byte preservation is critical

The downstream merger and field extraction depend on the LLM returning
exact key names (intent, origin, destination, departureDate, adults, city,
cityCode, keyword, latitude, longitude). Drift in the prompt could change
extraction subtly. The bridge task calls this out repeatedly: copy the
existing prompt body verbatim, do not rephrase, reorder fields, or change
indentation.

Regression smoke confirms identity: smoke `travel hotels in Paris on
2026-08-15` under all four providers; confirm classify_intent extracts
identical fields across providers (intent='hotels', cityCode='PAR'). If any
provider disagrees, the prompt drifted.

## Phases (5)

1. Apply refactor (lift prompt into workload, update three branches).
2. Ops PR.
3. Docs PR (tutorial 07 Step 3 polish).
4. Re-register + regression smoke under all four providers.
5. ai-meta pointer bumps. Stage but do not push.

## Cap

1 ops PR + 1 docs PR.

## Bridge artefacts

- `bridge/inbox/delegated/20260511-035000-classifier-prompt-single-source.task.json`
- `scripts/classifier_prompt_single_source_msg.txt`

## What's next after this lands

10. Anthropic re-smoke (gated on user provisioning the GCP secret in
    noetl-demo-19700101 — v2 task on disk but unstaged)
11. Activities NoETL-reference hydration bug — child result stored as
    reference, parent doesn't hydrate; affects all agent → MCP hops with
    large payloads. Lives in repos/noetl. Out of "ops + docs" scope; needs
    a noetl-engine round.

After #9 closes, the architectural arc has no obvious next round. The
travel agent is feature-complete. The two remaining items are gated/
out-of-scope for the cowork mode.
