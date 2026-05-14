# Travel fetches enough execution events for widget extraction

Date: 2026-05-13 23:46 PDT

After full-envelope extraction shipped, the Travel UI rendered bot text but still
missed the place card for execution `626407159353312247`. Inspection showed the
frontend was fetching only 20 execution events:

- `page_size=20` included terminal text and completion events, but did not
  include `append_widget_event`.
- `page_size=80` included `append_widget_event`, which carries the full widget
  envelope.
- `page_size=500` confirmed the execution had 212 total events.

Fix shipped in `repos/travel` PR #39:

- Increase `getExecution(id)` event page size from 20 to 100.
- Keep the existing `/noetl` gateway route and terminal event extraction logic.
- Add a code comment explaining why the UI needs enough history to include the
  widget emission event, not only the terminal `final_result`.

Validation:

- `npm run build` passed locally in `repos/travel`.
- `npm test -- --run` passed locally: 9 files, 19 tests.
- GitHub `Build and verify` passed on PR #39.
- PR #39 was squash-merged to `noetl/travel@c29d4da`.
- Main Cloudflare Pages deploy passed for run `25846093912`.
- Live `https://travel.mestumre.dev` serves asset `index-CFDQk47E.js`, and the
  deployed JavaScript contains `page_size:100`.

Design lesson:

For NoETL event-sourced widget UIs, the terminal event often carries text and a
shallow result projection, while the full widget envelope can sit tens of events
earlier in the event stream. The execution-detail fetch must include enough
events to cover both the terminal result and the widget emission.
