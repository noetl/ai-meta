# Duffel 5xx booking hardening + itinerary total-rollup fix SHIPPED+LIVE (#173/#174, 2026-07-02)
- Timestamp: 2026-07-02T20:25:58Z
- Author: Kadyapam
- Tags: muno,duffel,travel-planner,catalog-registration,prod-deploy,rollback,noetl-173,noetl-174

## Summary
Two Muno prod fixes deployed via CATALOG REGISTRATION (no image/worker redeploy — MCP python + planner python run in-worker; latest-wins). #173 Duffel MCP (ops#232 merged e3a94cf2): _request() retry-with-backoff (exp+jitter <=3) gated to idempotent-safe calls (search_offers/get_offer/search_places/get_airlines/offer_by_id/get_order/refresh); create_order NOT retried (Duffel has NO Idempotency-Key header -> double-booking risk) -> friendly 'Flights are temporarily unavailable, please try again in a moment.' via _error(user_message=) which keeps raw blob in _meta/data but shows friendly in summary (planner error_card.description reads summary). offer-fetch pre-check also routed friendly. Live catalog v18 cid 662330088389608328, ROLLBACK v17 cid 657453341483467614. #174 planner rollup (travel#93 merged c491e72a onto live v60-summary branch kadyapam/planner-v60-real-summary=travel#89, still unmerged to main): _summary_components() gates on confirmed order (order.id/booking_reference/slot.order_id) — not-confirmed prices from picked offer + 'selected'; confirmed uses order total + PNR; same guard mirrored to hotels. Fixes $0-total+(booked) for un-booked flight. Live catalog PLANNER v63 cid 662334888577598346, ROLLBACK v62 cid 660672070371509126. DEPLOY MECHANISM: python3 scripts/register_planner.py <yaml> <path> <name> (POST /api/catalog/register, rewrites metadata name/path, latest-wins) via PF localhost:18082->svc/noetl-server-rust:8082 in ns noetl on gke_noetl-demo-19700101. READ prod execs: POST /api/catalog/list (has full content); GET /api/replay/state?execution_id= -> commands -> GET /api/commands/{issued_event_id}; MCP tool result envelope is in the 'end' step command context (deep-find isError+summary); planner render in final_result->render_context.render_widget_chat.data. VERIFY: candidate at temp path -> inject duffel_api_base=unresolvable host in workload -> friendly-no-blob live; real TEST booking PNR QCA7FU $654.54 -> summary total_cost {654.54 USD}+PNR. Login unaffected (gateway LB 34.46.180.136 /api/auth/validate clean ~0.7s). create_order one-attempt/no-double-book proven offline (urlopen count). ops/travel ai-meta pointers NOT bumped (submodule trees hold unrelated in-flight work; deploy is registration not pointer).

## Actions
-

## Repos
-

## Related
-
