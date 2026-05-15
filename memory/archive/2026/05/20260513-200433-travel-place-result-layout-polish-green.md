# Travel place result layout polish GREEN

## Summary

After the `place_list` contract mismatch was fixed, the live Travel response
rendered but looked cramped: the assistant widget bubble shrink-wrapped to a
tiny card, the Paris place card collapsed into a narrow vertical tile, and the
follow-up place autocomplete collector also had no comfortable width.

## Fix

- `repos/travel` PR #31 merged as `b988cd6`.
- Assistant messages with widget envelopes now get a real content width
  (`min(100%, 920px)`) instead of shrink-wrapping to the widget's smallest
  possible width.
- `PlaceList` uses a full-width single-result layout and a two-column layout
  for multiple results.
- `PlaceCard` now renders as a horizontal card with a fixed photo rail,
  wrapped chips, a readable address block, and a stable CTA row.
- `PlaceAutocompleteInput` has a responsive width and stacks controls on small
  screens instead of collapsing into a tiny card.

## Validation

- `npm run test` passed.
- `npm run type-check` passed.
- `npm run build` passed.
- PR checks passed.
- Cloudflare Pages production deploy run `25839121874` completed successfully.

## Follow-up

Ask Kadyapam to hard-refresh `https://travel.mestumre.dev` and repeat
`trip to Paris`. Expected: the place result occupies a professional-width
widget area rather than a narrow sliver.
