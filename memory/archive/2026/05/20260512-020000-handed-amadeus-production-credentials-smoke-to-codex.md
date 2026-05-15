# Handed Amadeus production credentials + smoke to Codex (closes Round C)

- date: 2026-05-12T02:00:00Z
- tags: amadeus-production, codex-handoff, round-c-closure, cost-limited-smoke

## Round goal

Verify Amadeus production credentials in GCP, run a tightly-limited
production smoke (3 calls max), close the loop on Round C.

## Cost discipline

Production Amadeus API charges per request. Round limits:
- 1 token call
- 1 locations call (cheap endpoint, single offer return)
- 1 flights call (offers-search, ~$0.02-0.05 per Amadeus pricing)

That's it. No regression matrix. No mass smoking. Codex is explicitly
constrained.

## Amadeus account upgrade gate

Important: Amadeus production access requires explicit upgrade from the
self-service console (NOT automatic from test API). If Kadyapam's
Amadeus account hasn't completed the upgrade flow, production rejects
even valid credentials. This is independent of GCP secret provisioning.

If the smoke fails on the upgrade gate rather than the credential gate,
that's the signal for Kadyapam to complete the Amadeus-side upgrade
before re-firing.

## Phases (6)

1. Verify both GCP secrets exist + worker SA can read them.
2. Verify workload paths match where secrets got provisioned.
3. get_token smoke.
4. ONE locations call.
5. ONE flights call. STOP.
6. Close out — sync issue, memory, validation log.

## Bridge artefacts

- `bridge/inbox/delegated/20260512-020000-amadeus-production-credentials-and-smoke.task.json`
- `scripts/amadeus_production_credentials_and_smoke_msg.txt`

## What's after this — three threads named in the user's request

The user expanded scope in their last message. Three distinct threads:

### Thread 1 — Amadeus production (this round, fits cowork)
Tactical, ops-scoped, ~30 min. Closes Round C.

### Thread 2 — Alternative travel API (decision round, NOT this session)
User asked about "Google Travel API or something we can operate in
production mode." Real engineering decision. Options:
- Google Travel APIs (Hotel/Flights — partner status required)
- Duffel — modern airline API, $0.20/booking + ~$0 per search
- Skyscanner — affiliate-only, no booking API
- Booking.com Demand API — partner-gated
- Travelport / Sabre — enterprise GDS, complex onboarding

Each has different content licensing, cost model, and partner
requirements. This deserves a decision-doc round like Round D.

### Thread 3 — Payment integration + monetization (out of cowork scope)
User asked about "payment system + business steps for monetization."
This is NOT a bridge-task round. It needs Kadyapam's direct input on:

  Product model:
    - Booking aggregator (commission per booking)
    - Search SaaS (subscription)
    - Paid API (per-call)
    - White-label embed

  Payment processor:
    - Stripe / Adyen / regional rails
    - Hosted checkout vs embedded vs platform-billing
    - B2B vs B2C

  Compliance:
    - PCI scope (full vs SAQ-A via Stripe)
    - GDPR + data residency
    - Booking tax (varies by jurisdiction, non-trivial)
    - KYC/AML if becoming a financial intermediary

  Business positioning:
    - Customer = travelers? travel agencies? other devs?
    - Pricing tier strategy
    - Competitive landscape vs Kayak/Hopper/Booking.com/etc.

Recommendation: capture this as a separate planning doc (NOT a Codex
round). Once Kadyapam answers the four blocks above, the implementation
becomes much more tractable.

## Order of operations

1. Fire this round now (closes Round C, small).
2. Draft Thread 2 (alternative travel API decision doc) when ready.
3. Thread 3 needs a planning conversation, not a bridge round.

## Trigger prompt for Codex (paste after pushing)

```
Verify Amadeus production credentials in GCP and run a tightly-limited
production smoke (3 API calls max). Closes Round C.

Bridge task: bridge/inbox/delegated/20260512-020000-amadeus-production-credentials-and-smoke.task.json
Prompt details: scripts/amadeus_production_credentials_and_smoke_msg.txt
Result file: bridge/outbox/20260512-020000-amadeus-production-credentials-and-smoke.result.json

Run all 6 phases per the bridge task:
  1. Verify production secrets exist + worker SA can read.
  2. Verify workload paths match. 1 small ops PR if mismatch.
  3. get_token smoke (production endpoint).
  4. ONE locations call with amadeus_env=production override.
  5. ONE flights call with amadeus_env=production override. STOP.
  6. Close out: sync issue, validation log, memory entry.

Architectural rules:
  - 3 production API calls maximum.
  - Don't provision credentials yourself.
  - Don't modify the travel runtime classifier.
  - No release cut. No git push from ai-meta.

If credentials missing OR Amadeus account not upgraded to production:
AMBER + STOP, document what's missing for Kadyapam.

Production endpoint validation goal: prove production behaves better
than the test API's persistent 5xx flake from item #7.
```
