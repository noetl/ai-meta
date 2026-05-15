# Travel itinerary helper scope fix shipped

Date: 2026-05-14 00:02 PDT

The Muno trip-planner flow reached the party picker, but after submitting party
details the UI ended at `Ready.` and no flight/order path appeared. Inspection of
the underlying browser execution showed the party turn did dispatch the Duffel
flight search, but `normalize_tool_response` failed with:

```text
name '_itinerary_card' is not defined
```

The playbook later emitted a synthetic flight widget, but because the execution
had a failed command event, the browser did not present the expected flight batch
cleanly.

Fix shipped in `repos/travel` PR #40:

- Export `_airport_iata`, `_segment_card`, and `_itinerary_card` via
  `globals().update(...)` in `normalize_tool_response`.
- This matches the NoETL Python step authoring rule: helpers called from other
  helpers must be republished through globals because Python execution uses
  separate globals/locals dictionaries.

Validation:

- `npm run build` passed locally in `repos/travel`.
- `npm test -- --run` passed locally: 9 files, 19 tests.
- Attempted `noetl validate playbooks/itinerary-planner.yaml`, but this local
  NoETL CLI build has no `validate` subcommand.
- GitHub `Build and verify` passed on PR #40.
- Cloudflare Pages preview passed on PR #40.
- PR #40 was squash-merged to `noetl/travel@544eb8f`.
- GKE catalog re-registered `muno/playbooks/itinerary-planner` as version 31.
- Main Cloudflare Pages deploy passed for run `25846524413`.

Follow-up note:

One observed party-submit execution showed `event_payload` only contained
`action_id: submit_party`; the selected party value was not visible in the
normalized input. The agent still progressed to Duffel using defaults, but if
party state remains missing in the right pane, inspect widget-submit payload
serialization next.
