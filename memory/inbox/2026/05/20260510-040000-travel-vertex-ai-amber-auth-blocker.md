# Travel agent vertex-ai Phase 3 — AMBER (code GREEN, GCP auth blocker)

- date: 2026-05-10T04:00:00Z
- tags: travel-agent, vertex-ai, mcp-playbook, phase-3, amber, gcp-auth, codex-followup

## What landed

- Ops PR merged: noetl/ops#59 @ 97012403
- Docs PR merged: noetl/docs#50 @ 2206e353
- Travel runtime catalog v17 (was v13 after Phase 2)
- Vertex AI MCP playbook v3 (unchanged — single source of truth holds)
- ai-meta gitlinks bumped (3 commits ahead of origin/main, not pushed)
- Result: `bridge/outbox/20260510-021500-travel-vertex-ai.result.json`

## Code shape proven correct

- Three-branch refactor of classify_intent landed clean (Pydantic-validated).
- `start.next.arcs` dispatches on workload.ai_provider with `mode: exclusive`.
- `classify_via_vertex_mcp` (kind: agent → automation/agents/mcp/vertex-ai)
  creates a real NoETL agent sub-execution. `vertex_sub_execution_id` is
  captured in events for all three smokes — agent → MCP hop is real.
- The merger's fallback semantics worked exactly as designed: when the
  vertex MCP child returns isError, snap effective_provider to 'openai'
  with `provider_fallback_reason='service-account credentials missing
  private_key or client_email'` — that's literally the upstream error
  surfaced verbatim through the merger.
- All three smokes completed with widgets visible; no NoETL-side
  regressions; OpenAI default and Anthropic missing-secret fallback
  regressions clean.

## Codex caught two in-flight regressions

1. NoETL's separate globals/locals execution model — initial merger
   helper functions weren't visible to each other. Resolved by
   `globals().update(...)` + default-binding query/openai_api_key
   into the OpenAI fallback helper. Same pattern used in
   automation/agents/mcp/vertex-ai.yaml itself.
2. The Vertex child execution returns `command.failed` (not
   `command.completed`) when auth fails. The merger's child-event
   lookup initially missed the detailed error. Resolved by accepting
   command.completed / command.failed / call.error in the lookup.

Both lessons strengthen the merger pattern. Both worth a paragraph in
the playbook authoring guide if a docs round comes around.

## Why AMBER

The kind cluster's worker pod environment has `GOOGLE_APPLICATION_CREDENTIALS`
pointing at something that ISN'T a proper service-account JSON (no
`private_key` or `client_email` keys — looks like user ADC json instead
of an SA key). The Vertex AI MCP playbook's auth chain:

1. `GOOGLE_OAUTH_ACCESS_TOKEN` env — empty, skip
2. `GOOGLE_APPLICATION_CREDENTIALS` env — set, try service-account JWT
   path → fails because the file isn't an SA JSON
3. Metadata server fallback — never reached because step 2 raised

External MCP regression confirms the same path: `cd /mcp/vertex-ai;
call chat_completion ...` returns the identical error envelope. The
playbook IS reachable; auth IS the only blocker.

## Three paths to GREEN (Kadyapam picks one)

### Option A — GOOGLE_OAUTH_ACCESS_TOKEN (fastest, ephemeral)

```bash
export GOOGLE_OAUTH_ACCESS_TOKEN=$(gcloud auth print-access-token)
# Inject into worker deployment as env var, kubectl rollout restart
```

Token refreshes hourly. Good for one-shot smoke validation, not
production. Requires re-injection every ~1h.

### Option B — Service account key (stable, recommended for kind)

```bash
# Provision SA with Vertex AI permissions
gcloud iam service-accounts create noetl-vertex \
  --display-name="NoETL Vertex AI client" \
  --project=noetl-cluster

# Grant the SA aiplatform.user role
gcloud projects add-iam-policy-binding noetl-cluster \
  --member=serviceAccount:noetl-vertex@noetl-cluster.iam.gserviceaccount.com \
  --role=roles/aiplatform.user

# Generate key
gcloud iam service-accounts keys create /tmp/noetl-vertex.json \
  --iam-account=noetl-vertex@noetl-cluster.iam.gserviceaccount.com

# Mount into the kind worker pod via secret + GOOGLE_APPLICATION_CREDENTIALS env
kubectl -n noetl create secret generic vertex-sa-key --from-file=/tmp/noetl-vertex.json
# Then volume-mount in the worker deployment, env GOOGLE_APPLICATION_CREDENTIALS=/var/secrets/vertex-sa-key/noetl-vertex.json
```

Stable across pod restarts. Long-lived. Same shape that's used in GKE
production (just without Workload Identity).

### Option C — GKE Workload Identity (production-only)

Doesn't apply to kind. The kind cluster has no GCP metadata server.

## Re-smoke task pre-staged for when auth lands

- Bridge: `bridge/inbox/delegated/20260510-040000-travel-vertex-ai-resmoke.task.json`
- Prompt: `scripts/travel_vertex_ai_resmoke_msg.txt`

The re-smoke is small: verify auth path, run the three vertex-ai smokes,
expect effective_provider='vertex-ai' (NOT the openai fallback). Mirror
of the Anthropic re-smoke pattern.

## Architectural payoff held

Even with auth blocked, the round demonstrated the architectural thesis:
the MCP playbook IS the integration boundary. The travel agent never sees
GCP. When auth lands, three smokes flip to GREEN with no code change. The
travel runtime is now a thin dispatcher around two MCP playbooks (Amadeus +
Vertex) plus one urllib step (OpenAI/Anthropic).

## Deferred follow-ups carried forward

- GREEN re-smoke for Vertex AI once auth is configured (this memory entry covers it)
- Audit table re-add as side effect inside each render_* python step (psycopg)
- Wire hotels and activities branches in the travel agent
- app:form widget for refining Amadeus filters before re-running
- Anthropic re-smoke once the Anthropic secret is provisioned (still pending)
- Ollama provider — needs in-cluster bridge URL routing design
- Investigate Amadeus test API 500s on flights/locations
