# Duffel travel API integration — scoping

Date: 2026-05-12
Status: GREEN — shipped via ops#84 and docs#64; GKE registered Duffel MCP v2 and travel runtime v16

## Decision (locked)

Add **Duffel** as the new default flights provider, behind a
`flight_provider: duffel | amadeus` selector on the travel runtime,
**search-only** for the first integration cut. Booking, payment, and
live-airline content are explicitly out of scope until Thread 3 (payment +
monetization) advances.

Default `flight_provider` is **`duffel`** (search is $0 in test env, persistent
test-API 5xx flake on Amadeus is the operational pain motivating the switch).
Operators can revert any workload to Amadeus by setting `flight_provider:
amadeus`.

## Shipped State

Merged PRs:

- noetl/ops#84 (`a92d752`) — `automation/agents/mcp/duffel` plus travel runtime `flight_provider` selector.
- noetl/docs#64 (`5c394c3`) — Tutorial 07 selector documentation.

GKE registrations:

- `automation/agents/mcp/duffel` version 2, catalog `625385140687995289`
- `automation/agents/travel/runtime` version 16, catalog `625385144664195482`

Validation:

- Worker service account read the `duffel-api-test` secret and Duffel accepted it on `GET /air/airlines?limit=1`.
- Direct MCP `tools/list`, `search_offers`, `search_places`, and `get_airlines` completed.
- Default travel flights rendered 10 Duffel offers: execution `625385246619337115`.
- Amadeus override routed correctly and hit the known Amadeus test API 500 friendly-failure path: execution `625385670604751455`.

Result file: `bridge/outbox/20260512-130000-duffel-flights-mcp.result.json`.

The other three scoping questions in this doc are locked to their recommended
defaults — see the "Open questions" section below for the decisions.

## Why Duffel — and why search-only first

| Property | Amadeus self-service | Duffel |
|---|---|---|
| Search cost | Free in test, ~$0.02-0.05/offers-search in production | $0 in both `test` and `live` |
| Booking cost | Tier-dependent, typically %-of-fare | ~$0.20-$1.00 per order |
| Auth | OAuth2 client-credentials + per-env credentials | Static bearer token per env |
| Test env content | Synthetic, narrow | Synthetic, broader |
| Live content | Real airline inventory via GDS aggregation | NDC + direct + GDS, 200+ airlines |
| Hotels/activities/locations | Yes | Flights-only (Stays product is beta, gated) |
| Operational reliability today | Test API has the persistent 5xx flake tracked in `sync/issues/2026-05-11-amadeus-test-api-500s.md`; production unproven | Unknown for our load profile |

What Duffel gets us right now: a second flights source with $0 search cost, on
a static-bearer auth model that's far simpler than Amadeus OAuth. It also
**de-risks the Pattern C AMBER root cause**: if Amadeus test 500s on
locations/hotels keep biting, Duffel can carry the flights path while Amadeus
holds locations/hotels (which Duffel doesn't cover anyway).

What Duffel does not get us: hotels, activities, or "locations" in Amadeus's
sense. The travel runtime's locations/hotels/activities paths stay on Amadeus.
Duffel is a flights-only second source.

What we are not doing in this round:

- **Booking / orders / payment** — `POST /air/orders` and anything that
  creates a real reservation. Gated on Thread 3 (payment + monetization
  decisions: PCI scope, processor choice, KYC posture).
- **Duffel Stays** (hotels) — beta, partner-gated, no clear win over Amadeus
  hotels for our profile.
- **Live-environment content** — `duffel_live` requires KYC + commercial
  agreement. `duffel_test` is enough to ship the search path end-to-end.
- **Provider aggregation / dedup** — running Amadeus and Duffel in parallel
  and merging offers. Tempting, but adds dedup-by-itinerary, price-currency
  normalization, and ranking complexity. Defer.

## Provider selection model

Three plausible models. Recommendation is Option A.

- **Option A — exclusive selector** (locked):
  `flight_provider: duffel | amadeus`, one wins per execution. Default
  `duffel` (see locked decisions below). The travel runtime classifier
  routes flight steps to the chosen provider. Minimal code change:
  another conditional branch parallel to the `ai_provider` selector
  that's already there.

- **Option B — multi-source aggregation**: run both, merge offers,
  dedupe by carrier + flight number + departure time, sort by price.
  Better content coverage, much more work. Rejected for round 1.

- **Option C — auto-fallback on 5xx**: try Amadeus first, fall back to
  Duffel on persistent upstream failures. Operationally appealing
  (papers over the AMBER blocker), but it hides the underlying issue
  and complicates the "did this offer come from where?" debugging
  story. Revisit only if Amadeus production reliability turns out to
  be unacceptable after Round C closes.

## Architecture — mirroring Amadeus MCP shape

New MCP playbook: `repos/ops/automation/agents/mcp/duffel.yaml`. Surface
mirrors `automation/agents/mcp/amadeus.yaml`:

- `tools/list` → catalog of Duffel tools
- `tools/call` → dispatch on tool name

Tool catalog (search-only round):

| Tool | Duffel endpoint | Notes |
|---|---|---|
| `search_offers` | `POST /air/offer_requests` then `GET /air/offers` | Returns offer batch with itineraries + prices. The travel runtime's flights renderer consumes this shape. |
| `get_offer` | `GET /air/offers/{id}` | For deep-link / "show me more" UX on a specific offer. |
| `search_places` | `GET /places/suggestions` | Airport / city autocomplete. Replaces some of what Amadeus `search_locations` does, scoped to flight-relevant places. |
| `get_airlines` | `GET /air/airlines` | Optional. Reference data, useful for displaying airline names/logos. |

Explicitly **not** in this round: `POST /air/orders`, `GET /air/seat_maps`,
`POST /air/order_change_requests`, anything around payments or webhooks.

Travel runtime patch (`repos/ops/automation/agents/travel/runtime.yaml`):

- Add `flight_provider: duffel` to `workload` defaults (new default; `amadeus` is the explicit opt-out).
- Add `duffel_env: test` (test is the only value we'll wire initially).
- Add `duffel_token_path: projects/.../secrets/duffel-api-test/versions/1`
  pointing at a GCP Secret Manager secret holding the test bearer token.
- The flights step gets a parallel branch alongside the existing
  Amadeus-MCP hop: when `flight_provider == 'duffel'`, hop into the new
  `mcp/duffel` playbook instead.
- Capabilities list grows: `mcp:duffel`.

Runtime change is small (one selector branch, one keychain entry, one new
workload field). Most of the work is the new MCP playbook itself.

## Auth and credentials

Duffel auth is a single bearer token per environment. Provision in GCP Secret
Manager out-of-band, same pattern Amadeus production used:

```bash
echo -n '<duffel-test-token-from-dashboard>' | gcloud secrets create duffel-api-test \
  --replication-policy=automatic --project=noetl-demo-19700101 --data-file=-

gcloud secrets add-iam-policy-binding duffel-api-test \
  --project=noetl-demo-19700101 \
  --member=serviceAccount:noetl-worker-mcp@noetl-demo-19700101.iam.gserviceaccount.com \
  --role=roles/secretmanager.secretAccessor
```

Live token (`duffel-api-live`) is provisioned only when the booking path
opens up in a later round.

Token in the worker pod: read via the existing keychain pattern (the same
mechanism `amadeus_credentials` uses), then injected as
`Authorization: Bearer <token>` on every Duffel HTTP call.

## Cost ceiling

Search-only and on `duffel_test`: **$0**. Both per-call and per-order are zero
in the test environment.

If the round ever flips to `duffel_live`, search remains $0, but each
`POST /air/orders` (booking) costs ~$0.20-$1.00 depending on tier. We will not
enable that path until Thread 3 lands.

Per-execution cap: the travel runtime should keep the existing flights
result cap (typically 10 offers shown), so a single execution = one search
call. No risk of runaway burn in test.

## Implementation phases (rough)

This is what a Codex bridge round would look like once we want to fire it.
Not a commitment — sequencing here is the proposed shape.

1. **Pre-handoff (Kadyapam)**: create a Duffel developer account, mint a
   test token, run the gcloud secret recipe above, confirm worker SA can
   read.
2. **Phase 1 — duffel MCP playbook scaffold**: add
   `repos/ops/automation/agents/mcp/duffel.yaml` with the keychain entry,
   `tools/list` returning the four-tool catalog, and the `tools/call`
   dispatcher. No real Duffel calls yet — stub HTTP step.
3. **Phase 2 — wire search_offers end-to-end**: real `POST /air/offer_requests`
   + `GET /air/offers/{request_id}` flow. Map Duffel's offer schema to the
   travel runtime's flights widget shape.
4. **Phase 3 — wire search_places / get_offer / get_airlines**: smaller
   tools, same pattern.
5. **Phase 4 — travel runtime selector**: add `flight_provider` field,
   conditional hop into `mcp/duffel`. Default `amadeus` preserved.
6. **Phase 5 — smokes**: direct MCP search smoke, travel-runtime
   `flight_provider=duffel` smoke, comparison vs `flight_provider=amadeus`
   on the same prompt. All against `duffel_test`.
7. **Phase 6 — docs + closeout**: tutorial section + sync/memory.

Estimated PR count: 1-2 in `repos/ops` (playbook + runtime hook),
0-1 in `repos/docs`.

## Open questions — decisions locked

1. **Default provider**: **`duffel`** (Kadyapam call). Search is free, and
   moving the default sidesteps the persistent Amadeus test-API 5xx flake
   tracked in `sync/issues/2026-05-11-amadeus-test-api-500s.md`. Amadeus
   remains available as an explicit `flight_provider: amadeus` opt-out.
2. **Duffel `search_places` scope**: **autocomplete-only** for flight
   origin/destination input. The travel runtime's `locations` widget
   continues to use Amadeus `search_locations` regardless of
   `flight_provider`. Rationale: locations is a different intent than
   flight-place autocomplete; replacing it cross-cuts the Amadeus
   integration in a way that adds risk for no obvious win.
3. **Booking path timeline**: deferred to Thread 3 (payment + monetization).
   The MCP playbook scaffold in this round does NOT include order-related
   tool slots. When booking opens, add `create_order`, `get_seat_maps`,
   etc. then — they're additive to `tools/list`.
4. **Duffel Stays (hotels)**: skip indefinitely. Amadeus hotels stays the
   single hotels source. Revisit only if Amadeus hotels reliability or
   coverage becomes an issue.

Bridge round artefacts (this scoping doc → Codex):

- `bridge/inbox/delegated/20260512-130000-duffel-flights-mcp.task.json`
- `scripts/duffel_flights_mcp_msg.txt`
- `memory/inbox/2026/05/20260512-130000-handed-duffel-flights-mcp-to-codex.md`

## Related

- `repos/ops/automation/agents/mcp/amadeus.yaml` — pattern to mirror.
- `repos/ops/automation/agents/travel/runtime.yaml` — where the
  `flight_provider` selector lands.
- `sync/issues/2026-05-11-amadeus-test-api-500s.md` — the operational
  pain motivating a second provider.
- `sync/issues/2026-05-12-google-places-travel-enrichment.md` — Pattern C
  AMBER root cause; Duffel partially de-risks it for the flights path.
- `memory/inbox/2026/05/20260512-020000-handed-amadeus-production-credentials-smoke-to-codex.md`
  — Thread 2 (this doc) and Thread 3 (booking/payment) were both called
  out there.
