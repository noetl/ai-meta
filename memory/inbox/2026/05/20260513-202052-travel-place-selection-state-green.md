# Travel place selection state GREEN

## Summary

Kadyapam confirmed the place card now rendered, but clicking `Add to itinerary`
started another destination collection turn (`Miami` / `Where do you want to
go?`) and the right pane still showed Region as missing.

Root cause: the Places branch persisted only `places_seen` /
`total_results_seen`, while nested `region` dictionaries were unreliable across
NoETL projection surfaces. The CTA also emitted only an action id, so the
playbook had no selected place payload to promote into slot state.

## Fix

- `repos/travel` PR #32 merged as `1fc6154`.
- `PlaceCard` now emits a value payload with `label`, `id`, and `kind` for
  `add_place:<id>` CTA clicks.
- `ActionButton` supports an optional event value.
- The itinerary playbook treats `add_place` widget events as destination
  selection and advances to missing dates instead of reopening destination
  collection.
- The playbook now stores flat `region_label`, `region_city_code`,
  `region_country_code`, and `region_kind` fields alongside the nested region
  object so selected destinations survive NoETL projection.
- The shell merges partial slot-state updates and optimistically updates the
  right pane on place selection.

## Validation

- `npm run test` passed.
- `npm run type-check` passed.
- `npm run build` passed.
- GKE registered the patched playbook as v24 during smoke and v25 after merge.
- GKE smoke `626304632838422584`: `trip to Paris` returned `place_list` with
  `region_label=Paris`, `region_city_code=PAR`.
- GKE smoke `626304940020859406`: simulated `add_place` returned
  `date_range_picker` with Paris region fields preserved.
- Cloudflare Pages production deploy run `25839625500` passed.

## Follow-up

Ask Kadyapam to hard-refresh `https://travel.mestumre.dev` and retry:

1. `trip to Paris`
2. click `Add to itinerary`

Expected: right pane shows Region = Paris and the next chat widget asks for
dates, not another destination.
