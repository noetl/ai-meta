# Handed Google Places enrichment round to Codex (opt-in supplementary layer, Pattern C hybrid auth, free-tier disciplined)

- date: 2026-05-12T03:00:00Z
- tags: travel-agent, google-places, maps-static, routes, enrichment, opt-in, free-tier, pattern-c, hybrid-auth, workload-identity, codex-handoff

## Round goal

Add Google Places + Maps as an OPT-IN enrichment layer over the
travel agent's existing Amadeus integration. Photos, ratings, reviews,
hours surface in locations/hotels/activities widgets. Default behavior
unchanged. Free-tier disciplined with per-execution caps and GCP-level
quota ceiling.

## Auth pattern — Pattern C (hybrid)

After weighing three options (A: API key everywhere; B: pure SA OAuth;
C: hybrid), settled on Pattern C:

- **Backend Places + Routes API calls** → Workload Identity on the
  worker SA (`noetl-worker-mcp@noetl-demo-19700101.iam.gserviceaccount.com`).
  Same pattern as mcp/vertex-ai. No secret to manage.
- **Widget-embedded image URLs** (Maps Static + Place Photos) → restricted
  API key stored in `google-maps-widget-key` Secret Manager entry.
  Restrictions: HTTP referrer (mestumre.dev/* + gateway.mestumre.dev/*),
  API scope (Maps Static + Places API New only), per-day quota cap.

Why hybrid: SA OAuth is the right default for backend calls (matches
project security posture, no key to rotate). But browsers can't carry
SA tokens, so image URLs need an embedded key. The restricted widget
key has minimal blast radius if exposed.

Full setup recipe (single source of truth):
`playbooks/google-maps-platform-setup-pattern-c.md`

## Why this shape

User asked to "actually implement Google Travel — see end to end."
Reality check: Google Flights/Hotels public APIs don't exist. The
public APIs (Places, Maps Static, Routes) are content-enrichment-only.
This round implements what's actually possible — and gives the user
something they can hold and decide if it's enough or if a different
alternative-API decision is needed.

The free-tier discipline matters: $200/month Google Maps Platform
credit is plenty for demo + low-traffic production, but a runaway
loop or default-on enrichment could burn through it fast. Hence:
opt-in workload flag + per-execution cap + GCP-level quota cap on the
API key.

## Three layers of cost defense

1. **Default OFF**: `enrich_with_google_places=false` by default.
   Existing executions don't touch Google APIs at all.
2. **Per-execution cap**: max 10 enrichment calls (top-10 items per
   intent). Built into the playbook's `place_details` batch loop.
3. **GCP-level quota cap**: Kadyapam sets a per-day request quota on
   the API key as the hard ceiling.

If any one of these layers is bypassed accidentally, the others catch it.

## What surfaces in widgets

- **render_hotels enriched**: hotel photo (Maps Static URL or place
  photo ref), star rating + review count, one-line review snippet,
  address, geoCode.
- **render_locations enriched**: city/area photo, place type, rating.
- **render_activities enriched**: activity photo, rating, hours, price.
- **render_flights**: NO enrichment (flights don't map to places).
- **render_help**: NO enrichment.
- **render_amadeus_failure**: NO enrichment (degraded path stays simple).

If enrichment fails (API down, rate limit, bad key): graceful
degradation to original Amadeus-only widget. Same best-effort pattern
as the audit side-effect.

## Pre-handoff for Kadyapam

Five-step Pattern C setup. Authoritative recipe lives in
`playbooks/google-maps-platform-setup-pattern-c.md` (kept there so it
can be opened in Google Drive or referenced from any browser). Summary:

1. **Enable APIs** — `gcloud services enable places-backend maps-backend
   static-maps-backend routes` on noetl-demo-19700101.
2. **Grant SA serviceUsageConsumer** — required for the worker SA to
   call Places/Routes via Workload Identity. `gcloud projects
   add-iam-policy-binding noetl-demo-19700101 --member=serviceAccount:...
   --role=roles/serviceusage.serviceUsageConsumer`.
3. **Verify backend OAuth** — exec into a worker pod, call
   places.googleapis.com with `google.auth.default(scopes=['cloud-platform'])`
   token. Must return STATUS 200 (recipe in playbook Step 3).
4. **Create widget API key in Cloud Console** with restrictions:
   - HTTP referrers: mestumre.dev/*, gateway.mestumre.dev/*
   - API scope: Maps Static + Places API (New) only
   - Per-day quota: 5000 req/day each
5. **Store widget key in Secret Manager** as `google-maps-widget-key` +
   grant worker SA secretAccessor on the secret.

If pre-handoff isn't complete when Codex fires phase 1: AMBER + STOP
pointing Kadyapam at the setup playbook.

## What Codex builds

New playbook `automation/agents/mcp/google-places.yaml` with 5 tools
across two auth paths (Pattern C):

**Backend tools (SA OAuth via Workload Identity)**:
  - search_text — places:searchText
  - place_details (capped 10 chained calls) — places/{id}
  - nearby_search — places:searchNearby

**Widget URL builders (read widget key from Secret Manager, no HTTP)**:
  - static_map_url — returns `maps/api/staticmap?...&key=<widget-key>`
  - place_photo_url — returns `places/v1/<photo-resource>/media?key=<widget-key>`

Backend tools emit `Authorization: Bearer <SA token>` +
`X-Goog-User-Project: noetl-demo-19700101` headers — NOT
`X-Goog-Api-Key`. URL builders embed the widget key directly in the
returned URL string.

Travel runtime gets:
  - workload.enrich_with_google_places: false (default)
  - New step `enrich_with_google_places` between
    amadeus_via_mcp_<intent> and render_<intent> for the three
    enrichable intents.
  - Render steps gain enriched-mode rendering with graceful fallback —
    backend OAuth failure AND widget key failure both handled
    independently.

Cap: 1 ops PR + 1 docs PR.

## Bridge artefacts

- `bridge/inbox/delegated/20260512-030000-google-places-enrichment-mcp.task.json` (Pattern C dual-path auth)
- `scripts/google_places_enrichment_mcp_msg.txt` (Pattern C Codex prompt)
- `playbooks/google-maps-platform-setup-pattern-c.md` (Kadyapam setup recipe)

## What the user decides AFTER this lands

The original premise was "see end-to-end and decide what to do next."
This round delivers the realistic end-to-end. Decision points after:

1. Is the enriched UX enough to keep Google as the only supplementary
   layer? (Likely yes for demo + low-traffic.)
2. Do we still want a booking-grade alternative to Amadeus? (If yes,
   Duffel is the natural answer — was Thread 2's actual recommendation.)
3. Is the free-tier budget enough for the expected production traffic
   pattern? (Depends on Thread 3 product model.)

These remain user-decision points. No bridge round needed for the
decision itself.

## Trigger prompt for Codex (paste this in after pushing)

```
Add Google Places + Maps as an opt-in enrichment layer for the travel
agent. Pattern C hybrid auth: SA OAuth via Workload Identity for
backend Places/Routes calls; restricted API key from Secret Manager
embedded in widget image URLs. Default OFF. Photos + ratings + reviews
+ hours surface in locations/hotels/activities widgets when
workload.enrich_with_google_places=true.

Bridge task:   bridge/inbox/delegated/20260512-030000-google-places-enrichment-mcp.task.json
Prompt details: scripts/google_places_enrichment_mcp_msg.txt
Setup reference: playbooks/google-maps-platform-setup-pattern-c.md
Result file:   bridge/outbox/20260512-030000-google-places-enrichment-mcp.result.json

Pre-handoff requirements (Pattern C — full recipe in setup playbook):
  - 4 Maps Platform APIs enabled in noetl-demo-19700101
  - Worker SA has roles/serviceusage.serviceUsageConsumer
  - SA OAuth probe to places.googleapis.com returns STATUS 200
  - Widget API key (restricted: referrer + API scope + quota) stored as
    `google-maps-widget-key` in Secret Manager
  - Worker SA has secretmanager.secretAccessor on that secret

If any of those aren't ready: AMBER + STOP, point Kadyapam at
playbooks/google-maps-platform-setup-pattern-c.md.

Run all 9 phases per the bridge task. Architectural rules:
  - Supplementary layer, NOT replacement for Amadeus
  - Default OFF (opt-in via workload field)
  - Per-execution cap: max 10 enrichments (backend calls only)
  - Enrichment failure is non-blocking — fall back to Amadeus-only widget
  - **Pattern C is mandatory**: backend tools MUST use SA OAuth; widget
    URL builders MUST use the embedded restricted API key. Don't merge.
  - Free-tier disciplined
  - Don't provision the widget API key or modify SA IAM bindings yourself
  - No release cut. No git push from ai-meta.

Expected GREEN: phases 6/7/8 all succeed. Default behavior preserved
byte-for-byte. Enriched mode shows photos + ratings. Backend auth path
demonstrably uses SA OAuth (Bearer); widget URLs demonstrably embed
the restricted API key. Failure modes for BOTH paths fall back
gracefully (sub-smoke A revokes serviceUsageConsumer; sub-smoke B
corrupts widget key).
```

## What's left in the queue

This round closes Thread 2 with the actual realistic implementation
(Google as supplementary layer). After this lands:

- Amadeus production credentials + smoke (Round 1, already queued).
- Thread 3 (payment + monetization) remains a strategy conversation,
  not a bridge round.
