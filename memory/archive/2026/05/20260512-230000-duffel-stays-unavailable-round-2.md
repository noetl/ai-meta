# Duffel Stays unavailable on test account — Round 2 closed, hotels source stays Amadeus

- date: 2026-05-12T23:00:00Z
- tags: trip-planner, adiona, muno, duffel, stays, hotels-source, round-2, sales-gated

## Outcome

Duffel Stays is sales-gated. Our `duffel-api-test` token does not have
the Stays feature enabled. **Round 4 (LLM-driven itinerary agent) will
use Amadeus hotels as the hotels source**, with the documented 500-flake
caveat from `sync/issues/2026-05-11-amadeus-test-api-500s.md`.

## Probe — read-only, ran locally against GKE worker pod

Ran a Python probe from inside `noetl-worker-77bf5b5897-f2dtx` on
`gke_noetl-demo-19700101_us-central1_noetl-cluster`. Token loaded via
Workload Identity → Secret Manager REST API; never echoed. Each probe
called a Duffel `/stays/*` endpoint and recorded HTTP status + the
first 400 bytes of the response body.

| Endpoint | Status | Notes |
|---|---|---|
| `GET /air/airlines?limit=1` | 200 | sanity — token still works for Air |
| `GET /stays/accommodations?limit=1` | 404 | not a valid v2 Stays endpoint |
| `POST /stays/search` | **403** | `"This feature is not enabled for your account. Please contact sales to get access: https://duffel.com/contact-us"` |
| `GET /stays/rates?limit=1` | 404 | not a valid v2 endpoint |
| `GET /stays/quotes?limit=1` | 404 | not a valid v2 endpoint |
| `GET /stays/bookings?limit=1` | **403** | same sales-gating message as `/stays/search` |

The two endpoints that exist (`/stays/search`, `/stays/bookings`) both
return 403 with explicit sales-contact messaging. Stays beta access is
not a self-service toggle — it requires a commercial conversation with
Duffel.

## Decision (Round 4 hotels source)

- **Use Amadeus hotels** (`mcp/amadeus.search_hotels`) for the
  itinerary agent's hotels intent.
- Live with the known Amadeus test API 5xx flake; the friendly-failure
  path from the Duffel default-flights round (execution
  `625309687340073612`) already proves the runtime renders Amadeus
  errors gracefully.
- Re-evaluate Duffel Stays only if Kadyapam initiates a commercial
  conversation with Duffel.

## What this round did NOT need

- No Codex bridge round — too small. One read-only probe.
- No new GCP secret. Reused `duffel-api-test` provisioned in round
  20260512-130000.
- No PRs against `repos/ops` or `repos/docs`. The hotels-source
  decision is captured in this memory entry + the scoping doc update
  in the same commit.
- No travel runtime changes. The runtime already hops Amadeus for
  hotels.

## Cleanup

- `/tmp/duffel_stays_probe.py` deleted from worker pod + local.
- No log files left behind. Token never printed.
- Worker pod replica count unchanged (2/2).

## Trip-planner project status after this round

| Round | Status |
|---|---|
| 1 — Duffel test orders | ✅ GREEN |
| 2 — Duffel Stays availability check | ✅ closed, Stays unavailable → Amadeus hotels for Round 4 |
| 3 — Firestore MCP + event sourcing + replay tooling | next up |
| 4 — LLM-driven itinerary agent | hotels source LOCKED to Amadeus |
| 5 — Google Calendar | pending |
| 6 — muno bootstrap | pending |
| 7 — End-to-end tutorial | cap-stone |

## Related

- `sync/issues/2026-05-12-trip-planner-app-scoping.md`
- `sync/issues/2026-05-12-duffel-travel-api-integration.md`
- `sync/issues/2026-05-11-amadeus-test-api-500s.md`
- `bridge/outbox/20260512-130000-duffel-flights-mcp.result.json` (Amadeus override 5xx friendly-failure proof: execution `625309687340073612`)
- `bridge/outbox/20260512-220000-duffel-test-orders.result.json`
