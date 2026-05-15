# Handed travel render-audit side-effect round to Codex (executes the round 6 forward-pointer)

- date: 2026-05-10T22:30:00Z
- tags: travel-agent, audit, render-as-tail, psycopg, side-effect, codex-handoff

## Round goal

Re-add audit table writes to `travel_agent_events` as side effects inside
each render_* python step. The runtime carries an explicit forward-pointing
comment from round 6 telling future authors how to do exactly this. This
round executes on it.

## Why a side effect (not a trailing postgres step)

Round 6's render-as-tail fix dropped the trailing `persist_and_callback`
postgres step because it was clobbering render's result on the way to `end`.
The runtime.yaml comment at lines 1521-1527 says:

> If a dedicated audit table is needed later, add it as a SIDE EFFECT
> inside each render_* python step (psycopg) so it doesn't clobber the
> result. Don't reintroduce the trailing postgres step.

The recipe is already written. This round implements it.

## Five render_* steps, one shape

render_flights, render_hotels, render_locations, render_activities, and
render_amadeus_failure each get a best-effort psycopg INSERT at the BOTTOM
of their python `code` block (after widget building, before returning).
Wrapped in `try/except Exception` that prints a one-line warning to stdout
but never raises. Audit failure does not block the render.

## Audit row shape

```sql
INSERT INTO travel_agent_events (execution_id, event_type, ai_provider, intent, payload)
VALUES (%s, %s, %s, %s, %s::jsonb)
```

- event_type: `render_<intent>` per step (or `render_amadeus_failure`)
- ai_provider: from classify_intent.effective_provider
- intent: from classify_intent.intent
- payload: JSON with render_kind, render_type, envelope_status_code,
  envelope_ok, envelope_total, provider_fallback_reason, classified_intent

## Codex picks the connection-string source

Two viable patterns — Codex inspects the GKE worker pod env to decide:

(a) **Keychain pattern**: add a keychain entry exposing pg_k8s as a libpq
    connection string; pass via input.pg_url. Mirrors classify_intent's
    `openai_api_key: "{{ keychain.openai_token.api_key }}"` pattern. More
    NoETL-native.

(b) **Env-var pattern**: read NOETL_DB_HOST/PORT/USER/PASSWORD/NAME from
    os.environ. Avoids keychain churn but couples to env conventions.

I don't have visibility into the worker deployment env from this side, so
the choice is delegated. Codex documents the rationale in the result file.

## Comment cleanup

The lines 1521-1527 forward-pointing comment is removed and replaced with a
one-line note that audit is now executed as a side effect, with NoETL's
event log remaining the primary source of truth.

## Phases (5)

1. Validate design (inspect worker env; pick pattern; apply edits to all
   five render_* steps; Pydantic-validate; remove stale comment).
2. Ops PR: feat(travel-agent): re-add audit writes as side effects inside
   each render_* python step.
3. Docs PR: tutorial 07 paragraph noting the side-effect audit pattern.
4. Re-register + smoke. After each smoke, query travel_agent_events for the
   audit row. Sanity check: deliberately break the audit insert and verify
   the render result still surfaces.
5. ai-meta pointer bumps for ops + docs. Stage but do not push.

## Bridge artefacts

- `bridge/inbox/delegated/20260510-223000-travel-render-audit-side-effect.task.json`
- `scripts/travel_render_audit_side_effect_msg.txt`

## What's next after this lands

5. Anthropic re-smoke (gated on user provisioning the GCP secret)
6. Ollama provider — needs in-cluster bridge URL routing design
7. Investigate Amadeus test API 500s on flights/locations
8. NoETL-Python globals/locals idiom into the authoring guide as 13th rule
9. Single-source-of-truth refactor for the classifier system prompt
