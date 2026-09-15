# itinerary-planner deploy — ABORTED, registering main would have regressed prod

2026-09-15. Item 4 of the recovery mandate: "prod is 17 commits behind main,
deploy the safety backlog". **The premise was false and the action was aborted.**

## What the live planner actually is

`muno/playbooks/itinerary-planner` latest in the live catalog: **v113**,
495,630 bytes. Repo `main` is 477,850 bytes — prod is **larger**, not behind.

The live blob matches commit **`caf76bf`** — "fix(hotels): send a paxes element
per child so family searches work" — which lives on
**`origin/fix/341-children-paxes` and is NOT merged to main**.

```
live v113 has, main does NOT:
  caf76bf  fix(hotels): send a paxes element per child so family searches work
  8f10fd0  fix(hotels): derive stay dates at execution time; guard and classify
           provider failures

main has, live v113 does NOT:
  06dcaed  feat(widgets): flights-details playbook, richer hotel cards (the
           offer-cap 10->50 change from adiona/frontend#21)
```

**Registering main would have dropped two unmerged hotel fixes from production**
to add one non-safety cap change. Aborted under the "no destructive overwrite of
unrelated work" rule.

## The safety backlog is ALREADY LIVE

All three fixes named in the mandate are ancestors of the live artifact:

| commit | fix | ancestor of live? |
|---|---|---|
| `d4e8ba3` | a failed hotel booking must not render as confirmed | **YES** |
| `e90f39b` | a "View details" click must never book a flight | **YES** |
| `73dcc4a` | stop fabricating places, hotels, activities and transfers | **YES** |

Marker counts are identical between the live artifact and main
(`Do not invent inventory` 1/1, `fabricate flights, prices` 1/1, `error_card`
15/15, `book_this` 2/2, `Tier A` 8/8). There is no safety backlog to ship.

## ⚠ Correcting an earlier finding in this directory

`RECOVERY-2026-09-15.md` records prod's planner as **v17 = commit `2afcd05`,
17 commits behind main**. That reading came from the catalog store that was being
served *before* the `NOETL_CATALOG_READ_SOURCE=verify -> postgres` flip. It was
the stale store. The artifact prod actually executes is v113/`caf76bf`.

Both the "17 commits behind" claim and the plan built on it were wrong. Same
class as the two false zeros already recorded here: a confident read of the wrong
store.

## What should happen instead

Merge `origin/fix/341-children-paxes` into `main` so git and prod reconcile, then
register main once — that ships the cap change without dropping the hotel fixes.
That is a review-and-merge decision, not a deploy step.

Until then prod and main have genuinely diverged, and **`main` is not a safe
source to register for this path**.
