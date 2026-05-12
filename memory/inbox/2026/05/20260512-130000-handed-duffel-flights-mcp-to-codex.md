# Handed Duffel flights MCP integration to Codex (search-only, default duffel, test env, non-breaking opt-out to amadeus)

- date: 2026-05-12T13:00:00Z
- tags: travel-agent, duffel, flights-provider-selector, search-only, test-env, bearer-token-auth, codex-handoff

## Round goal

Add Duffel (https://duffel.com) as the new default flights provider for
the travel agent. Introduce a `flight_provider: duffel | amadeus`
selector on the travel runtime. Search-only first cut. Booking and live
content deferred to Thread 3 (payment + monetization).

## Decisions locked (from scoping doc)

Per Kadyapam's call on 2026-05-12 after the scoping doc
(`sync/issues/2026-05-12-duffel-travel-api-integration.md`) was drafted:

1. **Default `flight_provider: duffel`** — Kadyapam call. Free search +
   sidesteps the Amadeus test API 5xx flake.
2. **`search_places` is autocomplete-only** — locations widget keeps
   Amadeus `search_locations`.
3. **Booking deferred to Thread 3** — MCP scaffold does not include
   order tool slots.
4. **Duffel Stays skipped indefinitely** — Amadeus hotels stays.

## Auth model

- Static bearer token per environment.
- Test token (`duffel_test_*` prefix) provisioned in GCP Secret Manager
  as `duffel-api-test`. Worker SA `noetl-worker-mcp@...` gets
  `roles/secretmanager.secretAccessor`.
- Same `api.duffel.com` base URL for both test and live; token prefix
  determines the env.
- `Duffel-Version: v2` header on every call.

Pre-handoff recipe (Kadyapam runs before firing):

```bash
echo -n '<paste-duffel_test_-token>' | gcloud secrets create duffel-api-test \
  --replication-policy=automatic --project=noetl-demo-19700101 --data-file=-

gcloud secrets add-iam-policy-binding duffel-api-test \
  --project=noetl-demo-19700101 \
  --member=serviceAccount:noetl-worker-mcp@noetl-demo-19700101.iam.gserviceaccount.com \
  --role=roles/secretmanager.secretAccessor
```

Verify with `gcloud secrets versions access latest --secret=duffel-api-test ... | head -c 12` →
should print `duffel_test_`.

## Architecture

- New MCP playbook `repos/ops/automation/agents/mcp/duffel.yaml`,
  shape-parallel to `mcp/amadeus.yaml`.
- Tool surface: `search_offers`, `get_offer`, `search_places`,
  `get_airlines` (search-only).
- `search_offers` normalizes Duffel offers into the Amadeus-style
  envelope inside the playbook so `render_flights` stays unchanged.
- Travel runtime gets `flight_provider: duffel` workload field with
  conditional branch on the flights step. Non-flights intents
  (locations/hotels/activities) unchanged.
- `mcp:duffel` appended to runtime capabilities.

## Phases (8)

1. Verify Kadyapam's `duffel-api-test` secret + worker SA can read +
   token authenticates Duffel API (`GET /air/airlines?limit=1` → 200).
2. Author `mcp/duffel.yaml` (draft PR against repos/ops).
3. Direct MCP smokes (`tools/list`, `search_offers`, `search_places`,
   `get_airlines`).
4. Wire travel runtime selector (`flight_provider` workload field +
   flights step conditional branch).
5. Travel smoke with default Duffel.
6. Travel smoke with Amadeus override — confirms opt-out works. AMBER
   acceptable on the known Amadeus 5xx flake; only wiring regressions
   are blockers.
7. Tutorial 07 docs update (docs PR).
8. Close out — result JSON, codex-spike validation log entry, memory
   entry, scoping-doc status bump.

## Bridge artefacts

- `bridge/inbox/delegated/20260512-130000-duffel-flights-mcp.task.json`
- `scripts/duffel_flights_mcp_msg.txt`
- `sync/issues/2026-05-12-duffel-travel-api-integration.md` (scoping doc updated to locked-decisions state)

## Trigger prompt for Codex (paste after pushing)

```
Add Duffel as the new default flights provider for the travel agent.
Search-only first cut. Test environment only. `flight_provider: duffel |
amadeus` selector on the travel runtime, default `duffel`. Amadeus
remains a working opt-out via `flight_provider: amadeus`.

Bridge task: bridge/inbox/delegated/20260512-130000-duffel-flights-mcp.task.json
Prompt details: scripts/duffel_flights_mcp_msg.txt
Scoping doc: sync/issues/2026-05-12-duffel-travel-api-integration.md
Result file: bridge/outbox/20260512-130000-duffel-flights-mcp.result.json

Run all 8 phases per the bridge task. Architectural rules:
  - Search-only. No create_order, no seat_maps, no payment tools.
  - Test environment only. Live token path is a placeholder; do not
    exercise it.
  - Default `flight_provider: duffel`.
  - Locations/hotels/activities continue on Amadeus. `search_places`
    is for flight origin/destination autocomplete only.
  - Per-execution offer cap: 10 (enforced in mcp/duffel.yaml's
    search_offers result handler).
  - No release cut. No git push from ai-meta.

If Duffel test-token secret missing OR not readable by worker SA: AMBER
+ STOP, document what's missing.

Amadeus override smoke (phase 6) may AMBER on the known Amadeus test API
5xx flake — that's documented, not a regression. Only a "no branch
matched flight_provider=amadeus" failure indicates a wiring bug.
```

## What's after this — pointers

- **Round D follow-on**: pilot `flight_provider: duffel` in the GKE
  travel demo. After a few days of operational signal, decide whether
  to deprecate the Amadeus flights branch entirely or keep both
  long-term.
- **Thread 3 (payment + monetization)**: separate planning conversation,
  not a bridge round. Booking only opens once that conversation
  produces decisions on processor, PCI scope, and product model.
- **Round C closure**: still gated on Amadeus production credentials
  smoke (`bridge/inbox/delegated/20260512-020000-amadeus-production-credentials-and-smoke.task.json`).
  Independent of this Duffel round.

## Related

- `sync/issues/2026-05-12-duffel-travel-api-integration.md`
- `sync/issues/2026-05-11-amadeus-test-api-500s.md`
- `sync/issues/2026-05-12-google-places-travel-enrichment.md`
- `repos/ops/automation/agents/mcp/amadeus.yaml` (structural template)
- `repos/ops/automation/agents/travel/runtime.yaml` (flight_provider selector lands here)
