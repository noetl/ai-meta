# Classifier prompt single-source refactor closes GREEN — full deferred-list retrospective

- date: 2026-05-11T04:00:00Z
- tags: travel-agent, classifier, single-source-of-truth, green, arc-retrospective, cowork-session-complete

## Item #9 — what landed

- Ops PR: noetl/ops#67 — workload.classifier_system_prompt as single source
- Docs PR: noetl/docs#58 — tutorial 07 shows workload field + branch refs
- Travel runtime catalog 623495287473963591 v25
- Grep invariant verified: prompt body appears 1 time, workload reference 4 times
  (one definition + three branch references; the 4th hit is the workload key itself)

## GREEN smoke evidence

16-smoke classifier matrix passed clean — 4 intents (flights/hotels/locations/
activities) × 4 providers (openai default, anthropic fallback, vertex-ai
local fallback, ollama). Critical-field consistency across providers:

- hotels: cityCode='PAR', departureDate='2026-08-15' across all providers
- activities: keyword='Times Square', latitude=~40.758, longitude=~-73.9855
  across all providers
- flights: origin='SFO', destination='JFK', departureDate='2026-07-15',
  adults=2 across all providers

The byte-for-byte preservation worked. No drift. The free side benefit
(prompt overrides via workload for A/B testing) is now available to callers.

## Cowork session retrospective — seven rounds, one user instruction

Single user message ("one by one in order") drove seven sequential rounds:

| #  | round                                              | shape          | result |
| -- | -------------------------------------------------- | -------------- | ------ |
| 1  | Workload-default rule (12th authoring guide rule)  | docs           | GREEN  |
| 2  | Hotels and activities branches                     | ops + docs     | GREEN  |
| 3  | app:form refinement widget                         | gui + ops + docs | GREEN |
| 4  | Audit table side-effect inside render_* steps      | ops + docs     | GREEN  |
| 5  | (skipped — Anthropic re-smoke gated on user)       | smoke-only     | DEFERRED |
| 6  | Ollama provider via mcp/ollama playbook (Phase 4)  | ops + docs     | GREEN  |
| 7  | Amadeus 500 investigation                          | diagnostic     | GREEN (verdict b: sandbox flake) |
| 8  | Python globals/locals rule (13th authoring guide rule) | docs       | GREEN  |
| 9  | Classifier prompt single-source refactor           | ops + docs     | GREEN  |

Total: 9 rounds, 8 closed GREEN, 1 properly deferred. Plus 2 close-out
memory entries per round (handoff + GREEN audit), one validation log
append per GREEN round, and per-round bridge artefacts.

## Architectural state at session end

The travel agent is feature-complete as a NoETL-DSL-as-templating-library
demo:

- 4 AI providers, 3 routed via canonical MCP playbook hops
- 4 Amadeus tool surfaces (flights/hotels/locations/activities) all via
  the mcp/amadeus playbook hop
- 5 render branches with widget trees, render-as-tail, refinement forms
- Best-effort audit trail inside each render_* step
- Classifier system_prompt single-sourced via workload field
- 13 design rules pinned in the playbook authoring guide

The "MCP is just a playbook" thesis has 3 concrete load-bearing examples
in production: Amadeus, Vertex AI, Ollama. The arc has reached its
natural completion point.

## Lessons learned in this session

1. **The runtime is its own documentation.** Round 6's forward-pointing
   comment for the audit side-effect (item #4) was the recipe — the round
   just executed on it. Future-pointing comments in playbook YAML are real
   artifacts.

2. **Diagnose at the cluster/scope level before the auth-chain level.**
   The Phase 3 vertex-ai AMBER → GREEN was a project-name typo, not an
   auth misconfiguration. I wrote three wrong recipes before Codex spotted
   the actual issue.

3. **Browser smokes are the strongest signal.** Item #3's destination
   JFK→LAX click-test proved the full template-substitution → command-
   emission → re-run loop in a single user gesture.

4. **Defer expansion, prefer refactor when the diff is symmetric.**
   Item #9 was three duplications of the same string. The right move was
   one workload field, not three independent workload fields. Symmetry
   tells you when to consolidate.

5. **Codex catches and patches in-flight.** Multiple rounds (Phase 3,
   hotels/activities, Phase 4) had small regressions discovered during
   the round and fixed without escalation. The bridge handoff pattern
   trusts Codex to do this — and it works.

## Remaining deferred items (both blocked or out-of-scope)

10. **Anthropic re-smoke v2** — gated on user provisioning the GCP
    Anthropic secret in noetl-demo-19700101. Bridge task on disk but
    intentionally unstaged. Will fire when secret lands.

11. **Activities NoETL-reference hydration bug** — Amadeus returns 200,
    but the child playbook result is stored as a NoETL reference and the
    parent travel step doesn't hydrate it. Affects all agent → MCP hops
    once payloads get large. Lives in repos/noetl engine code, OUTSIDE
    the ops + docs scope this session has been operating in. Needs a
    separate noetl-engine round.

## Push state

ai-meta is heavily ahead of origin/main with the close-out commits from
this session (multiple memory entries, bridge artefacts, gitlink bumps).
Anthropic v2 re-smoke artefacts remain unstaged on purpose — pushing them
would fire the watcher prematurely.

## When to start a new session

When any of these happen:
- Anthropic GCP secret is provisioned → push the unstaged v2 artefacts;
  bridge fires.
- A new flagship arc is needed (e.g., extend travel beyond Amadeus, or
  a new domain agent).
- The activities reference-hydration bug becomes blocking enough to
  warrant a noetl-engine round.

Until then, the travel agent is shipping in its current state.
