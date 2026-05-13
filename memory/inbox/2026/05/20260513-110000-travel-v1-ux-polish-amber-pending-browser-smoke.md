# Travel v1 UX polish shipped, pending browser smoke

Date: 2026-05-13

Round:
- `bridge/inbox/delegated/20260513-100000-travel-v1-ux-polish.task.json`

Status:
- AMBER pending Kadyapam's production browser smoke.
- Code, docs, CI, and Cloudflare Pages deployment are GREEN.

Shipped:
- `noetl/travel#23` merged at `6609e3a`.
- `noetl/docs#70` merged at `8cc2975`.

Travel changes:
- Tool response normalization now carries compact place, hotel, offer, and order payload summaries into widget rendering.
- Place and hotel cards render real photo URLs when providers return them, with Material Skeleton fallback for missing or broken photos.
- Hotel card shows a first-photo hero and photo-count badge.
- `formatParty` renders traveller party strings such as `2 adults · 1 child (3 yrs)`.
- Itinerary summary and party trip-state slots use the formatter instead of raw JSON.
- Duffel create-order responses thread the real `booking_reference`, order id, total, currency, passengers, and slices into `order_confirmation`.
- The chat prompt explicitly forbids placeholder booking references such as `ABC123`.

Docs changes:
- Tutorial 08's "What is not covered in v1" list no longer includes the three resolved nits: placeholder photos, raw party display, and synthetic booking reference.

Validation:
- Travel: `npm run smoke:widgets`, `npm run test`, `npm run type-check`, `npm run build`.
- Playbook YAML parse succeeded.
- Docs: `npm run build`.
- Travel PR Cloudflare preview run `25826369626` passed.
- Travel production Pages run `25826497840` passed.
- Production bundle at `https://travel.mestumre.dev` contains the new photo fallback strings and no `ABC123`.

Browser smoke still needed:
- Incognito sign-in at `https://travel.mestumre.dev`.
- Prompt: `Trip to Paris next month for 2 adults and 1 child age 3`.
- Verify real place photo, real Duffel booking reference, and party string display.
- Hotel photos are GREEN if Amadeus returns 200; AMBER acceptable on that sub-check if the known Amadeus test API 5xx flake appears.
