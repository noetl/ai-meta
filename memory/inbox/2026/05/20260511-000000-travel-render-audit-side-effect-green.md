# Travel render-audit side-effect round closes GREEN — round 6 forward-pointer executed

- date: 2026-05-11T00:00:00Z
- tags: travel-agent, audit, render-as-tail, psycopg, side-effect, green

## What landed

- Ops PR: noetl/ops#65 — audit blocks in five render_* steps (c5ca5a1)
- Docs PR: noetl/docs#55 — tutorial 07 paragraph (6c3214a)
- Travel runtime catalog id 623450816443056661 v22
- Validation log appended: `bridge/outbox/codex-spike-green-validation.md`

## GREEN smoke evidence

- Playbook model validation passed.
- Docs build clean.
- Flights, locations, hotels, activities, plus a canvas-side locations smoke
  all completed with `app:column` render output.
- Audit rows landing in travel_agent_events for both classify_intent (from
  log_classification, unchanged from before) AND render_<intent> (new from
  this round). render_kind in the payload preserves the originating intent,
  even when the active renderer was render_amadeus_failure.
- Deliberate audit-insert failure → render still surfaced to the user. The
  best-effort try/except contract works as designed.

## Notable execution-context observation

Most smokes routed through render_amadeus_failure rather than render_flights /
render_hotels / etc. This isn't a regression — the Amadeus test API has been
returning HTTP 500 on flights/locations endpoints for several days, which is
exactly why the friendly-error renderer exists. The audit table now captures
this state explicitly: payload.render_kind is the intent the user asked for,
event_type='render_amadeus_failure' is the renderer that ran, and
envelope_status_code documents the upstream failure code. That's a clean
record for the deferred Amadeus 500 investigation.

## Architectural payoff

The runtime carried a forward-pointing comment from round 6 (six rounds ago
in elapsed-time terms, three days in calendar) that anticipated this exact
pattern. Reading the runtime's own design notes paid off: the recipe was
already there, the round just executed on it. Worth pinning as a meta-lesson:

> Future-pointing comments in playbook YAML are real artifacts. When you
> drop a tail step or restructure, leave a comment naming the deferred
> work AND the exact recipe to bring it back. The runtime is its own
> documentation for follow-up rounds.

## Deferred follow-ups remaining (in order)

5. Anthropic re-smoke once GCP secret is provisioned (gated on user) — NEXT
6. Ollama provider — needs in-cluster bridge URL routing design
7. Investigate Amadeus test API 500s on flights/locations
8. NoETL-Python globals/locals idiom into the authoring guide as 13th rule
9. Single-source-of-truth refactor for the classifier system prompt
