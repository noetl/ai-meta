# Travel flight CTA order routing fix

Date: 2026-05-14

Context:
- Browser smoke showed the Muno flight list rendered correctly after the helper-scope fix, but clicking `Book This` routed the next turn to Amadeus hotel search instead of Duffel order creation.
- The rendered flight CTA emitted `pick_offer:<offer_id>`. The itinerary playbook only created a Duffel order when text contained `book`, `order`, `confirm`, etc. A CTA click has no text, so the selected flight fell through to the `picked_flight && no hotel_search_results` branch.
- Clicking `Watch In Detail` had the same routing surface problem: it selected an offer and then advanced to hotels rather than rendering a flight detail card.

Fix:
- `repos/travel` PR #41 changed the flight card labels to concise `View` and `Book`.
- `Book` now emits `book_offer:<offer_id>` with an explicit `{ offer_id, action: "book_offer" }` payload.
- The playbook treats both the new `book_offer:<id>` and old already-rendered `pick_offer:<id>` actions as immediate Duffel `create_order` requests, preserving compatibility with stale cards already in the browser.
- `View` now emits/keeps `view_offer:<id>` and the playbook renders a `flight_detail` card instead of touching the hotel branch.
- Normalized flight cards are stored in `slot_state.flight_offers` after search so detail views can re-render the selected offer.

Validation:
- `npm run build`
- `npm test -- --run`
- `npm run smoke:widgets`
- GKE playbook registration: `muno/playbooks/itinerary-planner` version 33
- GitHub PR checks and Cloudflare Pages main deploy passed.

Follow-up:
- Browser smoke should retry the flow from a fresh `trip to Paris` thread. Existing flight cards from before v33 should still book because `pick_offer:<id>` is now back-compatible, but new cards will show `View` / `Book`.
