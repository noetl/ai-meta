# Travel Duffel order passenger fix

Date: 2026-05-14

Context:
- After the flight CTA routing fix, browser execution `626437732784407044` correctly reached `mcp/duffel.create_order`.
- Duffel rejected the test order with HTTP 422 because synthetic passenger `given_name` values like `TestAdult1` failed format validation and `gender` was required.
- Browser execution `626437514135339233` also exposed a flight-detail branch bug: `render_widget_chat` failed with `name 'picked_offer_id' is not defined`. This was caused by Python `exec` globals/locals behavior around a generator expression.

Fix:
- `repos/travel` PR #42 updates synthetic test passengers:
  - alphabetic given names (`Alex`, `Jordan`, etc.) instead of digit-suffixed names
  - explicit `gender` values for adults and children
- The flight-detail branch now uses a plain loop to locate the selected offer, avoiding generator-expression scope leakage.

Validation:
- `npm run build`
- `npm test -- --run`
- `npm run smoke:widgets`
- GKE playbook registration: `muno/playbooks/itinerary-planner` version 34
- GitHub PR checks and Cloudflare Pages main deploy passed.

Follow-up:
- Browser smoke should retry `Book` from a fresh flight list. The expected next widget is `order_confirmation` with a real Duffel test booking reference. If Duffel still rejects the order, inspect the new `mcp/duffel.create_order` response excerpt for the next schema requirement.
