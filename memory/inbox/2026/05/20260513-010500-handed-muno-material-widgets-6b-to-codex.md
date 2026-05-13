# Handed real Material widget components to Codex (trip-planner Round 6b)

- date: 2026-05-13T01:05:00Z
- tags: trip-planner, adiona, muno, react, mui, material-ui-v6, theme, figma, widgets, codex-handoff, round-6b

## Round goal

Replace the 23 stub components at `muno/src/components/widgets/*.tsx`
(JSON-as-card placeholders from Round 4a/6a) with real Material UI v6
implementations matching the Adiona Figma. Replace the placeholder
`muno/src/theme.ts` with a Figma-derived MUI theme. Add the necessary
runtime deps to `muno/package.json` (MUI X date pickers, react-google-maps,
react-markdown, Inter font). Container build must remain GREEN after.

Runs PARALLEL with Round 4b. Disjoint paths in muno — 6b touches
`muno/src/` only, 4b touches `muno/playbooks/` only.

## Decisions locked

- **Lives entirely in muno**. No repos/ops/docs/noetl changes.
- **MUI v6** (Material Design 3) for everything except DateRangePicker
  (use the unencumbered MUI X variant OR react-day-picker).
- **Google Maps JS API** via @vis.gl/react-google-maps. Key delivered
  to browser via Vite build-time env var `VITE_GOOGLE_MAPS_KEY`. The
  existing `google-maps-widget-key` secret is already referrer-restricted
  so browser embedding is safe-by-design.
- **Theme path**: try Variables endpoint (if PAT scope available); fall
  back to inspecting `Material Theme` page frame fills via the existing
  `file_content:read` scope. Either acceptable.
- **Inter font** via @fontsource/inter.
- **Desktop-first scope**. Mobile responsive deferred to a later round
  (documented in `muno/docs/architecture/responsive-design.md`).
- **Container build remains GREEN**. Image size target < 100 MB.
- **muno PR via standard flow**.

## Pre-handoff (OPTIONAL)

Cleanest theme path needs `file_variables:read` PAT scope. Kadyapam
can optionally generate a fresh token with both scopes and push as a
new version to `figma-access-token`:

```bash
echo -n '<figd_...>' | gcloud secrets versions add figma-access-token \
  --project=noetl-demo-19700101 --data-file=-
```

If not done, the round uses the frame-inspection fallback. Round still
ships either way.

## Bridge artefacts

- `bridge/inbox/delegated/20260513-010500-muno-material-widgets-6b.task.json`
- `scripts/muno_material_widgets_6b_msg.txt`

## Trigger prompt for Codex

```
Replace 23 JSON stubs with real Material UI v6 widgets at
muno/src/components/widgets/*.tsx + write a Figma-derived theme at
muno/src/theme.ts. Adiona Figma. Container build must remain GREEN.
Trip-planner Round 6b. Runs parallel with Round 4b.

Bridge task: bridge/inbox/delegated/20260513-010500-muno-material-widgets-6b.task.json
Prompt details: scripts/muno_material_widgets_6b_msg.txt
Scoping doc: sync/issues/2026-05-12-trip-planner-app-scoping.md
Result file: bridge/outbox/20260513-010500-muno-material-widgets-6b.result.json

Pre-handoff (OPTIONAL): if figma-access-token has file_variables:read
scope, theme pulls cleanly from /variables/local; else fall back to
frame inspection on the Material Theme page.

Run all 8 phases per the bridge task. Architectural rules:
  - Lives in muno/src/. NO changes to muno/playbooks/ (Round 4b).
  - Theme: Variables endpoint if available; else frame inspection.
    Either acceptable.
  - Google Maps JS key via Vite VITE_GOOGLE_MAPS_KEY env var at build.
  - All 23 widgets validate-and-render against sample envelopes in
    muno/playbooks/agent/widget_envelope_examples.md (created by
    Round 4b — coordinate via main).
  - Container build remains GREEN. Image size < 100 MB target.
  - Desktop-first scope. Mobile responsive deferred.
  - muno PR via standard flow.
  - ai-meta pointer bump local-only.
  - If Round 4b's PR lands first: rebase before merging.
```

## Widget map summary

23 widgets across 6 categories:
- **Plain text (4)**: BotText, UserText, TypingIndicator, ClarifyQuestion
- **Interactive (4)**: DateRangePicker, PartyPicker, PlaceAutocompleteInput, ActionChooser
- **Lists (3)**: FlightList, HotelList (with upsell_banner), PlaceList
- **Cards (4)**: FlightCard, HotelCard, HotelCompare, PlaceCard (with variants)
- **Layout (3)**: MapView, FilterPanel, PropertyBlock
- **Lifecycle (4)**: LoadingCard, ErrorCard, Notification, OrderConfirmation
- **Closure (1)**: ItinerarySummary

Total: 23.

## What's after this round

- **Round 5** — Google Calendar integration (independent; can start
  any time after Round 4b is GREEN).
- **Round 7** — End-to-end tutorial (cap-stone; depends on 4b + 6b
  both shipping).

## Related

- `sync/issues/2026-05-12-trip-planner-app-scoping.md`
- `memory/inbox/2026/05/20260513-002608-muno-bootstrap-container-build-green.md`
- `bridge/inbox/delegated/20260513-010000-itinerary-agent-4b.task.json` (parallel round)
- `muno/playbooks/widget-contract/*.schema.json` (source of truth for widget shapes)
- `muno/src/components/WidgetRenderer.tsx` (central dispatcher)
- `scripts/figma_fetch.sh`
- Figma file key: `BSbpbRHzFGF2LmJl7Ekemb`
