# Duffel test orders GREEN

Date: 2026-05-12 16:05 PT

Round 1 of the trip-planner project landed the Duffel test-order tools.

What shipped:

- `automation/agents/mcp/duffel` now exposes 7 tools.
- Added `create_order`, `get_order`, and `list_orders`.
- Existing search tools remain unchanged.
- Order creation is test-environment only.
- Payment mode is Duffel wallet `balance` only.
- The travel runtime was intentionally untouched; itinerary-agent order dispatch is a later round.

Merged PRs:

- ops#85, merge `efbd378`
- docs#65, merge `dd44279`

GKE registration:

- `automation/agents/mcp/duffel` v5, catalog `625453996051792863`

Preflight:

- Existing `duffel-api-test` secret is present.
- Worker SA has `secretmanager.secretAccessor`.
- Worker read the token through ADC; token value was not recorded.
- Duffel `/air/airlines?limit=1` and `/air/orders?limit=1` both returned HTTP 200.

Smokes:

- Post-merge tools/list: `625454064293118944`, 7 tools.
- Search offers: `625452805850923904`, 10 capped offers.
- Create test order: `625452830463099795`, booking reference `XKQAYC`, order id `ord_0000B6EeISs9tYodkIZlhY`.
- Get order: `625452855905747878`, same order/booking reference.
- List orders: `625452878764704697`, 2 orders visible.
- Invalid offer guard: `625452902571574220`, completed with `isError=true` and handled Duffel `not_found` instead of crashing.

Fix-forward:

- Changed Duffel MCP `_error` to keep the NoETL step green while setting `isError=true` and `control_data.status=error`. This preserves MCP recoverability for the itinerary agent.

Rule:

- Never log full token bytes or full payment blocks. Result/memory only record order id, booking reference, amount/currency/type summaries, and execution ids.
