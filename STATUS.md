# STATUS

Present-tense working state for the current session arc. Updated as work lands.
History lives in the [ai-meta wiki's Sessions Log](https://github.com/noetl/ai-meta/wiki/Sessions-Log);
open work lives in the [`ai-task` issue queue](https://github.com/noetl/ai-meta/issues?q=is%3Aopen+label%3Aai-task).
This file is the short answer to *"what is in flight right now."*

**Last updated:** 2026-10-04

## Waiting on the owner

`noetl/noetl` enforces an approving review with admin enforcement, so these cannot be
self-merged. All green.

| PR | What |
| :-- | :-- |
| [noetl/noetl#707](https://github.com/noetl/noetl/pull/707) | the #400 publish guard — refuses a release that would upload nothing |
| [noetl/noetl#708](https://github.com/noetl/noetl/pull/708) | drop the dependabot config whose only directory left the repo in March |
| [noetl/noetl#709](https://github.com/noetl/noetl/pull/709) | declare `noetl.event_dead_letter` in the DDL the deploy actually applies |

And one prod action, deliberately not taken:

- [#410](https://github.com/noetl/ai-meta/issues/410) — apply the fixed `PodMonitoring`.
  The manifest fix is merged ([ops#321](https://github.com/noetl/ops/pull/321)); applying it
  resumes a scrape that has been dark for 25 days, which can satisfy a paging condition on the
  first scrape. Choosing the hour is the owner's call.

## Open, tracked

| Issue | State |
| :-- | :-- |
| [#400](https://github.com/noetl/ai-meta/issues/400) | guard written and RED-proved; open until noetl#707 merges |
| [#410](https://github.com/noetl/ai-meta/issues/410) | manifest fixed, prod apply pending (above) |
| [#406](https://github.com/noetl/ai-meta/issues/406) | accepted upstream wait — `quick-xml` ×2 + `rsa`/Marvin. **Not a blocker.** A current published lock reads **3**, and that is the expected number |
| [#360](https://github.com/noetl/ai-meta/issues/360) | reopened; acceptance box 6 un-ticked 2026-10-04 because the green was measured over a window shorter than the mechanism's period |
| [#234](https://github.com/noetl/ai-meta/issues/234) | ⚠ **do not sweep.** One remaining reference is a *working* dependency on the old project — the travel Maps secret exists only there |

## Shipped this arc

Closed: #361, #374, #375, #378, #385, #390, #395, #398, #402.

- **PyPI `noetl` 5.1.1** published and verified on the artifact — 4 files sha256-matched,
  shipped lock byte-identical to the repo's, RustSec **5 → 3** with the previous release's lock
  scanned first as a positive control.
- **Clippy gates on all 5 Rust repos**, allow-lists 23 → 2, and **all 7 Rust repos pin 1.99.0**.
- **PR gates for ops / e2e / apt**, plus a daily sweep over all **15** wikis (243 md files).
- **apt arm64 built every release** (2.8.7 → 5.0.3 newest arm64); orphaned `.deb`s 22 of 23 → 0 of 26.

## Standing cautions for whoever picks this up

- **A green over nothing is a failure.** Every check here prints the population it measured.
  Several "clean" results this arc were a scan that examined zero things.
- **Read the rate, not the total.** A large denominator over a short window is not a result —
  see #360.
- **Diff the whole object before any prod apply**, never the field you changed
  (`agents/rules/apply-safety.md`). That is what caught ops#321 nearly dropping two pods from
  monitoring while fixing something else.
- **A closing keyword in prose closes the issue.** `closed #400` inside a heading shut #400 on
  merge; see `agents/rules/commit-conventions.md` for the detector.
