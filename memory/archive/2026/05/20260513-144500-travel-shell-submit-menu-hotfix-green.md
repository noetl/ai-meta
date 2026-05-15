# 2026-05-13 — Travel shell submit/menu hotfix GREEN

Context: Kadyapam reported that the left Search/Orders menu was not switching and chat messages were not submitting on `travel.mestumre.dev`.

Diagnosis:
- `repos/travel/src/components/shell/Sidebar.tsx` rendered static Search/Orders buttons with no active state or click handlers.
- `repos/travel/src/components/shell/ChatThread.tsx` rendered sample widget envelopes and its form only called `preventDefault()`, so no itinerary-agent execution was started.

Fix shipped in `noetl/travel#24`:
- Added shell-level `activeView` state in `src/App.tsx`.
- Wired `Sidebar` Search/Orders buttons to that state.
- Replaced static sample chat rendering with an interactive chat loop that submits `user_message`, `user_widget_submit`, and `user_widget_cta_click` turns to `playbooks/itinerary-planner.yaml`.
- Added `getExecution(id)` to poll execution status and render `execution.result.render` through the existing `WidgetRenderer`.
- Orders view now filters to `order_confirmation` widgets and shows an empty-state alert when no orders exist.
- Errors from submit/poll are surfaced in the shell instead of silently swallowing the interaction.

Validation:
- Local `npm run test` passed: 8 files, 18 tests.
- Local `npm run type-check` passed.
- Local `npm run smoke:widgets` passed for 24 widget envelopes.
- Local `npm run build` passed.
- PR checks passed.
- Cloudflare Pages main deploy `25828094295` completed successfully for merge SHA `7a1902f`.

State:
- `repos/travel` now points at `7a1902f` locally in `ai-meta`.
- Browser smoke still needs Kadyapam confirmation: open `https://travel.mestumre.dev/`, sign in, submit a free-form trip prompt, verify a planning widget appears, then switch Search/Orders and confirm Orders shows order confirmations after placing a Duffel test order.
