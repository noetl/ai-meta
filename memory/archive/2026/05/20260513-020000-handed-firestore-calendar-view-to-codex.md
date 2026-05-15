# Handed Firestore-backed calendar view to Codex (trip-planner Round 5 — RESHAPED)

- date: 2026-05-13T02:00:00Z
- tags: trip-planner, adiona, muno, firestore, calendar, widget, no-google-calendar, codex-handoff, round-5

## Round goal

Add a `calendar_view` widget to muno (24th template), extend the
itinerary agent to write calendar event docs to Firestore on order
confirmation, and implement the Material `<CalendarView />` component
that renders them.

**Reshaped from original scope**: Kadyapam locked storage to
Firestore-only. NO Google Calendar API integration in this round (or
ever — post-tutorial roadmap entry only). The original plan of "SA
creates a Google Calendar, ACLs Kadyapam" was rejected in favour of
keeping the data plane entirely inside Firestore + muno.

Lives ENTIRELY in muno. No repos/ops changes. No new GCP setup. No
new MCP tools. No new secrets.

## Decisions locked

- **Firestore-only storage**. No external calendar sync. Kadyapam's
  explicit call.
- **Catalogue grows additively** from 23 to 24 widgets. Existing
  schemas unchanged; no schema_version bump.
- **Live mode + static mode** both supported on `calendar_view` —
  agent picks based on context (static for itinerary_summary
  snapshots, live for standalone "show me my schedule").
- **Firestore security rules**: v1 permissive (public read on
  chat_threads/trips/users; writes blocked from clients — only worker
  SA writes via mcp/firestore). Documented but NOT deployed from this
  round; Kadyapam deploys manually.
- **No new GCP secrets**. Live mode uses an unauthenticated Firebase
  JS SDK read.
- **Post-tutorial roadmap**: ICS export + optional per-user Google
  Calendar push via OAuth user consent flow are documented in
  `muno/docs/architecture/calendar-design.md` but explicitly out of
  v1 scope.

## Pre-handoff (DONE)

Nothing required from Kadyapam.

## Bridge artefacts

- `bridge/inbox/delegated/20260513-020000-firestore-calendar-view.task.json`
- `scripts/firestore_calendar_view_msg.txt`

## Trigger prompt for Codex

```
Firestore-backed calendar view in muno. Adds calendar_view widget +
agent calendar event writes + Material CalendarView component. NO
Google Calendar — Firestore only per Kadyapam's reshaped scope.
Trip-planner Round 5.

Bridge task: bridge/inbox/delegated/20260513-020000-firestore-calendar-view.task.json
Prompt details: scripts/firestore_calendar_view_msg.txt
Scoping doc: sync/issues/2026-05-12-trip-planner-app-scoping.md
Result file: bridge/outbox/20260513-020000-firestore-calendar-view.result.json

Pre-handoff: NONE.

Run all 8 phases per the bridge task. Architectural rules:
  - Firestore-only. NO Google Calendar API, NO ICS export.
  - Lives entirely in muno. No repos/ops/docs/noetl changes.
  - Catalogue grows additively from 23 to 24 widgets.
  - Live mode: unauthenticated Firebase SDK reads against v1 permissive
    rules. Document clearly.
  - Firestore rules authored but NOT deployed.
  - muno PR via standard flow.
  - ai-meta pointer bump local-only.
  - Container build remains GREEN. Image size < 60 MB.
```

## What's after this round

- **Round 7** — End-to-end tutorial (cap-stone). Depends on 4b + 6b +
  5 all shipped.

## Related

- `sync/issues/2026-05-12-trip-planner-app-scoping.md` (Firestore data model)
- `memory/inbox/2026/05/20260513-010000-itinerary-agent-4b-green.md`
- `memory/inbox/2026/05/20260513-010500-muno-material-widgets-6b-green.md`
- `memory/inbox/2026/05/20260512-235900-firestore-mcp-event-sourcing-green.md`
- muno main at fdd7dc9 (post 6b)
