# Travel slot-state loader hotfix GREEN

Date: 2026-05-13 20:51 PT

Kadyapam reported that the Travel/Muno planner looped between "Where do you want to go?" and "Choose dates" after selecting Paris, so the flow never reached Duffel flight search.

Diagnosis: the itinerary playbook loaded Firestore through `mcp/firestore.get_doc`, but `_slot_from_loaded` only handled a raw `data` object. The actual MCP response shape is `{ok, path, found, document: {data: ...}}`. When a date widget submitted only `{from,to,nights}`, the playbook dropped the saved `region` fields, persisted dates-only state, and the next turn correctly thought the destination was missing.

Fix shipped in `noetl/travel#33`:

- `playbooks/itinerary-planner.yaml` now unwraps Firestore `document.data` and also accepts already-unwrapped slot-state dictionaries.
- `DateRangePicker` emits `action_id: submit_dates`.
- `PartyPicker` emits `action_id: submit_party`.

Validation:

- `npm run test`
- `npm run type-check`
- `npm run build`
- GKE playbook re-registered as `muno/playbooks/itinerary-planner` version 27.
- GKE smoke completed the full path: `place_list` -> `date_range_picker` -> `party_picker` -> `flight_list`.
- Smoke executions: `626319859160187041`, `626320017746821751`, `626320101020533646`, `626320185695142053`.
- Cloudflare Pages production deploy `25840527501` completed successfully.

User-facing result: after selecting a place and submitting dates, the app now asks for travellers; after submitting party, it calls Duffel and renders flight results instead of looping back to destination collection.
