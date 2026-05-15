# Travel app:form refinement round closes GREEN — refinement UX live in canvas + terminal

- date: 2026-05-10T22:00:00Z
- tags: travel-agent, app-form, refinement, widget, gui-v1.11.0, green

## What landed

- GUI PR: noetl/gui#34 — `ghcr.io/noetl/gui:v1.11.0` deployed
- Ops PR: noetl/ops#64 — travel runtime catalog id 623435726075462094 v21
- Docs PR: noetl/docs#54 — tutorial 07 'Refinement forms' subsection

## GREEN smoke evidence

- AppForm unit tests pass (4 cases: static string, placeholder substitution, missing field, non-string fallback).
- GUI typecheck/build clean. Docs build clean. Playbook Pydantic validation clean.
- All four travel intents complete with app:column + app:form widget tree.
- **The decisive smoke**: browser test changed destination from JFK → LAX, clicked
  'Try again with new values', form emitted the substituted command
  `travel flights from SFO to LAX on 2026-07-15 for 2 adults`. New execution
  `623439294278926715` completed with `render_type=app:column`. The full
  template-substitution → command-emission → re-run loop is real.

## Architecture status

The travel agent is now a complete demo of:
- Three AI providers (OpenAI, Anthropic, Vertex AI — last via MCP hop)
- Four Amadeus tools (flights, hotels, locations, activities — all via MCP hop)
- Widget output in five render branches + the failure renderer
- Refinement forms appended to every output, closing the read-only loop
- "MCP is just a playbook" thesis with three concrete load-bearing examples

## Sequencing decision held up

The bridge task required gui PR + redeploy BEFORE the ops PR opened, on the
grounds that ops alone would emit a values-dict to runCommand which expects a
string. Codex executed that ordering. No regression slipped in.

## Deferred follow-ups remaining (in order)

4. Audit table re-add inside render_* python steps (psycopg) — NEXT
5. Anthropic re-smoke once GCP secret is provisioned (gated on user)
6. Ollama provider — needs in-cluster bridge URL routing design
7. Investigate Amadeus test API 500s on flights/locations
8. NoETL-Python globals/locals idiom into the authoring guide as 13th rule
9. Single-source-of-truth refactor for the classifier system prompt
