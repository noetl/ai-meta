# Travel place_list null rating hotfix GREEN

## Summary

After the Gateway callback fix landed, the live browser advanced to rendering
the returned widget and exposed the next contract issue:

`Unable to render this response (template mismatch): data/items/0/rating must be number, data/items/0/rating_count must be integer`

The Google Places MCP can return `null` for rating fields on locality-style
results such as Paris. `place_card` makes `rating` and `rating_count` optional,
but when present they must be numeric. The itinerary playbook normalizer was
including the keys with `null` values.

## Fix

- `repos/travel` PR #30 merged as `1ff4fbb`.
- `_place_card` now omits optional `rating` and `rating_count` unless the
  provider value satisfies the schema type (`number` and `integer`
  respectively).

## Validation

- `npm run test` passed.
- `npm run type-check` passed.
- `npm run build` passed.
- PR checks passed.
- GKE registered the merged playbook as catalog version 22
  (`626284629799993724`) for `muno/playbooks/itinerary-planner`.
- Direct GKE smoke execution `626282394185630630` completed in 16s at
  `final_result` after registering the same hotfix as v21.

## Follow-up

Ask Kadyapam to hard-refresh `https://travel.mestumre.dev` or use incognito and
retry `trip to Paris`. Expected: the `place_list` renders instead of falling
back to the schema mismatch message.
