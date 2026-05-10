# Handed travel app:form refinement round to Codex (3 PRs: gui + ops + docs)

- date: 2026-05-10T20:15:00Z
- tags: travel-agent, app-form, widget, refinement, gui-extension, codex-handoff

## Round goal

Add an app:form refinement widget to every travel render_* tree so users can
edit Amadeus filters and re-run without typing a new prompt. Form fields are
pre-populated from classify_intent's output; submit button emits a `key:
"command"` widget event with a templated natural-language travel query that
gets substituted at click time from the current field values.

## Why this needs a gui PR first

`app:form` widget already exists and is plumbed into both surfaces. Both the
terminal (NoetlPrompt) and canvas (GatewayAssistant) handle `key: "command"`
widget events with string values — terminal calls `runCommand(value)`, canvas
calls `commandToCanvasPrompt(value, message) + onSubmit`.

The MISSING primitive is template substitution. The current AppForm click
handler emits either `button.event.value` (static string) OR the form values
dict. Neither builds a string command from the current values. The gui PR
adds `{fieldId}` placeholder substitution to the click handler.

Sequencing matters: gui PR must merge AND the cluster must redeploy gui
before the ops PR opens. If ops lands first, a click on the form emits the
values dict (object) to `runCommand(value)` which expects a string and would
break.

## Per-intent form shapes

| intent     | fields                                          | command template                                                        |
| ---------- | ----------------------------------------------- | ----------------------------------------------------------------------- |
| flights    | origin, destination, departureDate, adults      | `travel flights from {origin} to {destination} on {departureDate} for {adults} adults` |
| hotels     | cityCode, departureDate                         | `travel hotels in {cityCode} on {departureDate}`                        |
| locations  | keyword                                         | `travel locations near {keyword}`                                       |
| activities | keyword                                         | `travel activities near {keyword}`                                      |
| failure    | classified-intent's matching field set + button | matching template per intent — pick at render time                       |

For activities, the form takes a place name (keyword) rather than raw
lat/long because the classifier already geocodes natural-language queries.
This keeps the form values human-friendly while letting the classifier do
the IATA / lat-long extraction on rerun.

## What does NOT change

- Amadeus and Vertex AI MCP playbooks (single source of truth).
- classify_intent or its system prompt.
- The widget kind enum — app:form already exists.
- Widget event plumbing in NoetlPrompt and GatewayAssistant.
- The render-as-tail pattern.

## Phases (6)

1. GUI PR: AppForm template substitution + unit test (4 cases: static, placeholder, missing field, non-string fallback).
2. Redeploy gui to GKE — wait for the semantic-release auto-tag and
   confirm the noetl-gui deployment is rolled to the new image.
3. Ops PR: append app:form to each render_*.
4. Docs PR: tutorial 07 'Refinement forms' subsection.
5. Re-register + smoke. Click-test each form. Verify a new execution starts
   with the substituted command.
6. ai-meta pointer bumps for gui + ops + docs. Stage but do not push.

## Bridge artefacts

- `bridge/inbox/delegated/20260510-201500-travel-app-form-refinement.task.json`
- `scripts/travel_app_form_refinement_msg.txt`

## Why not skip the gui change and use AppButton quick-picks instead?

Option considered. AppButton with hardcoded `key: "command"` quick-picks
already works and would skip the gui PR. But quick-picks aren't a form —
they don't let the user type new field values. The deferred follow-up
specifically called for an app:form for refining filters. A few more lines
of click-handler code is the right cost for the right capability.

## What's next after this lands

From the post-flagship deferred list (in order):

4. Audit table re-add inside render_* steps (psycopg)
5. Anthropic re-smoke (gated on user provisioning the GCP secret)
6. Ollama provider — needs in-cluster bridge URL routing design
7. Investigate Amadeus test API 500s on flights/locations
8. (NEW) NoETL-Python globals/locals idiom into the authoring guide as 13th rule
9. (NEW) Single-source-of-truth refactor for the classifier system prompt
