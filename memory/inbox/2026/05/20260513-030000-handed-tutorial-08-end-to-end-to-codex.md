# Handed end-to-end trip-planner tutorial to Codex (trip-planner Round 7 — cap-stone)

- date: 2026-05-13T03:00:00Z
- tags: trip-planner, adiona, muno, tutorial, docs, cap-stone, codex-handoff, round-7

## Round goal

Write the cap-stone tutorial for the Adiona/muno trip-planner project
at `repos/docs/docs/tutorials/08-trip-planner-end-to-end.md`. Walks a
developer through a complete trip-planning session in muno against the
GKE NoETL backend. Uses 8 screenshots Kadyapam captured during his
local demo run.

After this round, the trip-planner project is **feature complete +
tutorial shipped**. Roadmap items (real-money booking, mobile
responsive, multi-user auth, ICS export, Google Calendar push, photo
wiring, party display polish) all explicitly deferred to post-tutorial.

## Pre-handoff (DONE)

Screenshots captured at `/Volumes/X10/projects/adiona/tutorial_screenshots/`:

  01-chat-start.png
  02-places-card.png
  03-date-picker.png
  04-flight-search.png
  05-picked-flight.png
  06-hotel-search.png
  07-calendar-view.png
  08-itinerary-summary.png

No new GCP setup, no new secrets. Lives entirely in repos/docs.

## Decisions locked

- Tutorial 08 is purely additive — does NOT modify tutorial 07.
- Lives in repos/docs (not muno) — it's a public-facing tutorial in
  the existing tutorials series.
- Honest about v1 polish nits — Party JSON rendering, photo
  placeholders, synthetic booking ref display, date consistency — all
  surfaced in the 'What's NOT covered' section.
- All cited execution IDs are real values pulled from prior round
  result JSONs.
- No production-mode claims. Test env only, repeated in Vision section.

## Bridge artefacts

- `bridge/inbox/delegated/20260513-030000-tutorial-08-end-to-end.task.json`
- `scripts/tutorial_08_end_to_end_msg.txt`

## Trigger prompt for Codex

```
End-to-end trip-planner tutorial (Adiona/muno cap-stone). Round 7.
Single repos/docs PR. Screenshots already captured at
/Volumes/X10/projects/adiona/tutorial_screenshots/ (8 PNGs).

Bridge task: bridge/inbox/delegated/20260513-030000-tutorial-08-end-to-end.task.json
Prompt details: scripts/tutorial_08_end_to_end_msg.txt
Scoping doc: sync/issues/2026-05-12-trip-planner-app-scoping.md
Result file: bridge/outbox/20260513-030000-tutorial-08-end-to-end.result.json

Pre-handoff: NONE.

Run all 5 phases per the bridge task. Architectural rules:
  - Lives in repos/docs only. NO changes to muno or other repos.
  - Use the 8 captured screenshots verbatim. NO new screenshot capture.
  - No production-mode claims; repeat 'test env only' in Vision.
  - All credential examples use <...> placeholders.
  - All cited execution IDs are real values from bridge/outbox/.
  - Honest about v1 polish nits in 'What's NOT covered'.
  - docs PR via standard flow.
  - ai-meta pointer bump local-only.

If the docs build can't run locally in the codex sandbox: note in
result JSON and proceed; Kadyapam eyeballs the rendered PR.
```

## What's after this round

The trip-planner project ships. Optional post-tutorial work, sequenced
roughly by user value:

1. **Real booking flow** — Thread 3 (payment + monetization). Live
   Duffel tokens, payment processor, PCI scope.
2. **Mobile responsive** — Round 6c using the Figma's mob-* variants.
3. **Firebase Auth** — replace Guest mode with user accounts; tighten
   Firestore security rules.
4. **Photo wiring** — pull Google Places + Amadeus photos through to
   the card renderers.
5. **Party display + booking ref polish** — small UI cleanup.
6. **Filter narrowing widgets** — agent emits star rating / budget /
   amenities filter widgets, supports the 'Show Numbers' /
   filter-refinement turns.
7. **ICS export** — small Round, mostly client-side.
8. **Optional Google Calendar sync** — per-user OAuth (NOT SA-owned
   approach we rejected); only if a user explicitly asks for it.

None of these block 'feature complete'. The current ship plus the
tutorial is the milestone.

## Related

- `sync/issues/2026-05-12-trip-planner-app-scoping.md` (the master plan)
- All 7 prior round memory files in memory/inbox/2026/05/*-green.md
- All 7 prior round result JSONs in bridge/outbox/
- `/Volumes/X10/projects/adiona/tutorial_screenshots/` (the 8 PNGs)
- `repos/docs/docs/tutorials/07-travel-agent-with-widgets.md` (the convention reference)
