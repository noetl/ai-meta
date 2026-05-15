# Handed Duffel test-env order creation tools to Codex (Round 1 of trip-planner project)

- date: 2026-05-12T22:00:00Z
- tags: trip-planner, adiona, muno, duffel, orders, test-env, codex-handoff, round-1

## Round goal

Extend `repos/ops/automation/agents/mcp/duffel.yaml` (currently
search-only after round 20260512-130000) with three order management
tools — `create_order`, `get_order`, `list_orders` — scoped strictly to
Duffel's test environment. Test orders are free + synthetic, use the
Duffel test wallet `balance` payment type. No real money, no real
ticketing.

## Context

This is Round 1 of the trip-planner chat app (Adiona/muno) per the
scoping doc at `sync/issues/2026-05-12-trip-planner-app-scoping.md`.
Independent of the new agent/UI architecture; just builds the API
surface the LLM-driven itinerary agent (Round 4) will use to book
flights once a user picks an offer from search results.

Why this is Round 1: it ships in a single Codex pass, no new GCP
setup, low risk, and produces a measurable Duffel test-order proof
(booking reference returned) without depending on Firestore (Round 3)
or muno (Round 6).

## Scope locked

- Test env only. `duffel_live_token_path` remains a placeholder.
- Reuses existing `duffel-api-test` GCP secret (round 20260512-130000).
- Three tools added; search tools unchanged.
- Travel runtime (`automation/agents/travel/runtime.yaml`) NOT
  modified. Orders dispatch is Round 4 territory.
- Tutorial 07 gets a brief test-env-orders subsection.

## Pre-handoff (Kadyapam, one-time)

- Visit https://app.duffel.com, switch env to **test**, verify wallet
  balance ≥ $1000 USD equivalent. Top up via dashboard if needed
  (Duffel auto-credits the test wallet).
- No new GCP secret. The existing `duffel-api-test` token should
  authorize the order endpoints; phase 1 probes `GET /air/orders?limit=1`
  to confirm. If 403, regenerate the Duffel token with order scopes
  enabled.

## Architecture

- Same Duffel REST shape as the search round: `Authorization: Bearer
  <token>`, `Duffel-Version: v2`, JSON.
- New tools follow the existing MCP `tools/call` dispatch pattern.
- create_order does light input validation (passengers non-empty,
  offer not expired) before POSTing — surfaces validation errors as
  clean `status: error` envelopes the eventual agent can react to.
- `tools/list` catalog grows from 4 to 7 entries.

## Phases (5)

1. Pre-handoff verify (secret + IAM + orders endpoint authorized on
   the token).
2. Author the three tools in `mcp/duffel.yaml`; update `tools/list`.
   Open ops PR.
3. Direct MCP smokes — tools/list, search→pick→create_order,
   get_order, list_orders, expired-offer guard.
4. Tutorial 07 brief subsection. Open docs PR.
5. Close out — result JSON, codex-spike validation log entry, memory
   entry (lands in ai-meta/memory/ for this round since muno doesn't
   exist yet; later trip-planner outcome entries will land in
   muno/memory/inbox/codex/ once Round 6 bootstraps muno).

## Bridge artefacts

- `bridge/inbox/delegated/20260512-220000-duffel-test-orders.task.json`
- `scripts/duffel_test_orders_msg.txt`

## Trigger prompt for Codex (paste after pushing)

```
Add Duffel test-env order creation tools (create_order, get_order,
list_orders) to mcp/duffel. Test environment only — no real money, no
real ticketing. Round 1 of the trip-planner project (Adiona/muno).

Bridge task: bridge/inbox/delegated/20260512-220000-duffel-test-orders.task.json
Prompt details: scripts/duffel_test_orders_msg.txt
Scoping doc: sync/issues/2026-05-12-trip-planner-app-scoping.md
Result file: bridge/outbox/20260512-220000-duffel-test-orders.result.json

Pre-handoff: Duffel test wallet balance ≥ $1000 USD via
https://app.duffel.com (test env). `duffel-api-test` secret already
provisioned in round 20260512-130000 with worker SA
`secretAccessor`. Phase 1 probes `/air/orders?limit=1` to confirm the
existing token authorizes order endpoints.

Run all 5 phases per the bridge task. Architectural rules:
  - Test env only. Live token path is a placeholder.
  - Wallet `balance` payment type only.
  - Travel runtime is untouched. Orders dispatch is Round 4 territory.
  - tools/list catalog grows from 4 to 7. Existing tools unchanged.
  - No retry-on-429. No release cut. No git push from ai-meta.
  - Never log full payment blocks or token bytes. Booking references OK.

If pre-handoff fails OR `/air/orders` returns 403 on the existing
token: AMBER + STOP, document what's missing for Kadyapam.
```

## What's after this — Round 2

Round 2 — Duffel Stays (hotels) beta availability check. Lightweight
investigation: read-only probe from worker pod to determine if Duffel
Stays endpoints are reachable on our test account. Informs Round 4's
hotel source decision (Duffel Stays if available, Amadeus hotels
otherwise).

## Related

- `sync/issues/2026-05-12-trip-planner-app-scoping.md`
- `sync/issues/2026-05-12-duffel-travel-api-integration.md`
- `memory/inbox/2026/05/20260512-130000-handed-duffel-flights-mcp-to-codex.md`
- `bridge/outbox/20260512-130000-duffel-flights-mcp.result.json`
- `repos/ops/automation/agents/mcp/duffel.yaml`
- https://duffel.com/docs/api/orders
