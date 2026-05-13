# Handed travel v1 UX polish to Codex (Round 10 — first post-Round-9 functional iteration)

- date: 2026-05-13T10:00:00Z
- tags: trip-planner, travel, ux, polish, photo-wiring, party-formatter, booking-reference, codex-handoff, round-10

## Round goal

First post-Round-9-GREEN UX iteration. Knocks down three of the
documented v1 polish nits from tutorial 08 'What's NOT covered':

1. **Photo wiring** — Google Places photo URLs threaded into PlaceCard
   renders; Amadeus hotel photos threaded into HotelCard. Today both
   render grey placeholders.
2. **Party display polish** — `{adults, children: [{age}]}` formatted
   as `'2 adults · 1 child (3 yrs)'` everywhere it's displayed.
3. **Real Duffel booking reference** — OrderConfirmation widget shows
   the real `booking_reference` (e.g. `XKQAYC` per the round 1 smoke
   on execution `625452830463099795`) instead of the synthetic
   `ABC123` placeholder.

Pure repos/travel work + small tutorial 08 update. Single travel PR.

## Pre-handoff (Codex auto-verifies)

- travel main at post-Round-9-hotfix SHA (currently `09694e2`).
- Maps widget API key (`travel-agent-widget-key`) referrer allowlist
  includes `https://travel.mestumre.dev/*` AND
  `http://localhost:5173/*`. If missing: AMBER + STOP; Kadyapam adds
  via Cloud Console.
- All baseline npm scripts GREEN.
- Existing GCP secrets accessible to noetl-worker-mcp (unchanged).

No new GCP setup. No new IAM. No new secrets.

## Decisions locked

- Schemas remain backwards-compatible. Photo fields added as
  OPTIONAL only. No schema_version bump.
- Photo fetch failures degrade gracefully to Material Skeleton or
  styled placeholder — never crash the card.
- Booking reference threading is a system-prompt + payload-construction
  fix; NOT an LLM-prompt-engineering rewrite.
- Hotel card renders first photo + 'View all N photos' badge for v1;
  fancy carousel deferred.
- Cloudflare Pages auto-deploys preview + prod. Codex verifies preview
  before merging to main.
- Kadyapam-side browser smoke against production is the GREEN gate.

## Bridge artefacts

- `bridge/inbox/delegated/20260513-100000-travel-v1-ux-polish.task.json`
- `scripts/travel_v1_ux_polish_msg.txt`

## Trigger prompt for Codex

```
Travel v1 UX polish — photo wiring + party display formatter +
real Duffel booking reference. Three documented v1 polish nits from
tutorial 08. Pure repos/travel work + tutorial 08 'What's NOT covered'
trim. Trip-planner Round 10 (first post-Round-9 functional iteration).

Bridge task: bridge/inbox/delegated/20260513-100000-travel-v1-ux-polish.task.json
Prompt details: scripts/travel_v1_ux_polish_msg.txt
Scoping doc: sync/issues/2026-05-12-trip-planner-app-scoping.md
Result file: bridge/outbox/20260513-100000-travel-v1-ux-polish.result.json

Pre-handoff (auto-verified in phase 1): travel main at the
post-Round-9-hotfix SHA; Maps widget key referrer allowlist includes
travel.mestumre.dev + localhost:5173. No new GCP setup.

Run all 8 phases per the bridge task. Architectural rules:
  - Lives in repos/travel + repos/docs (tutorial 08 trim) only.
  - NO auth/gateway/Firestore changes.
  - Photo fields added as OPTIONAL — no schema_version bump.
  - Photo fetch failures degrade to Material Skeleton placeholder.
  - Booking reference fix is system-prompt + payload-construction;
    LLM must pull fields verbatim from the latest agent_tool_response.
  - Cloudflare Pages auto-deploys preview + prod. Verify preview
    before merging to main.
  - Kadyapam-side browser smoke against production is the GREEN gate.
  - Never echo tokens / credentials.

If Maps widget referrer doesn't cover travel.mestumre.dev: AMBER +
STOP. Kadyapam adds via Cloud Console.

If Amadeus 500-flakes during hotel-photo smoke: AMBER acceptable on
that single sub-check; friendly-failure rendering remains documented
behaviour from Round 5.
```

## Smoke checklist Kadyapam runs after main deploy

1. Open https://travel.mestumre.dev/ in incognito (no cached session).
2. Sign in with the existing Auth0 test user (don't paste passwords).
3. Reach the chat shell. Free-form prompt: 'Trip to Paris next month
   for 2 adults and 1 child age 3'.
4. Verify place card (Eiffel Tower or similar) shows a REAL photo,
   NOT a grey placeholder.
5. Pick a flight. Place a test order.
6. Verify OrderConfirmation shows a REAL Duffel booking reference
   (not `ABC123`).
7. Verify Trip state pane / itinerary_summary renders party as
   '2 adults · 1 child (3 yrs)' (or similar human-readable form).
8. Verify hotel cards (when Amadeus 200s) show photos. AMBER on the
   hotel sub-check is acceptable if Amadeus 5xxs — that's the known
   test API flake.

## What's next after this round

Remaining v1 polish nits from tutorial 08:
- Filter narrowing widgets (star rating slider, budget range,
  amenities chip group) — agent doesn't yet emit them. Separate round.
- Full property block right-pane surfacing — slot accumulator should
  show all collected slots, not just destination + dates.
- Date consistency between picker and rendered events.
- Trip state pane completeness.

Plus the auth/security follow-ups still on the post-Round-9 roadmap:
- NoETL server-side JWT validation.
- Per-uid Firestore rules + authenticated Firebase reads.

## Related

- `sync/issues/2026-05-12-trip-planner-app-scoping.md`
- `scripts/travel_gateway_session_auth_green_handoff_to_claude_msg.txt`
- `repos/docs/docs/tutorials/08-trip-planner-end-to-end.md`
- `bridge/outbox/20260512-220000-duffel-test-orders.result.json`
  (real booking ref `XKQAYC` example)
- travel main at `09694e2` going in
