# STATUS

Present-tense working state for the current session arc. Updated as work lands.
History lives in the [ai-meta wiki's Sessions Log](https://github.com/noetl/ai-meta/wiki/Sessions-Log);
open work lives in the [`ai-task` issue queue](https://github.com/noetl/ai-meta/issues?q=is%3Aopen+label%3Aai-task).
This file is the short answer to *"what is in flight right now."*

**Last updated:** 2026-10-05 — **monitoring**

## 🟢 MONITORING — no agent-actionable work remains

As of 2026-10-05 the autonomous queue is empty. This is not "nothing is open"; it is
**nothing is open that an agent should take**. Measured before saying so:

| check | result |
| :-- | :-- |
| latest completed run **per workflow** on all 16 default branches | **0 currently failing** |
| `noetl/server` v3.123.0 release | 7 of 7 jobs success, amd64 + arm64 + manifest, AR `latest,v3.123.0` |
| `drift-audit.sh` checks touched this session | `env-docs` OK · `inert-tests` OK (566 first-party files) · `schema-copies` identical at the recorded pointers · `pinned-sets` 3 registrations present on `main` |
| scheduled wiki sweep | green, 15 of 15 wikis, 243 md files |

⚠ Two cautions on those numbers, both earned today. The per-workflow sweep still lists
dead Dependabot update-ids as "failing" forever, because each update gets its own
workflow name and its last run is permanently that failure — `noetl/noetl`'s four are
all from **before** `dependabot.yml` was removed. And `drift-audit.sh` reads the
**working tree**: in the primary checkout 22 of 33 submodule trees differ from their
pointers, so two checks read as regressions when they were not. That is now the first
thing the audit prints.

### What is open, and why an agent should not take it

- [#410](https://github.com/noetl/ai-meta/issues/410) — apply the fixed `PodMonitoring`.
  **The owner's call**: it resumes a 25-day-dark scrape and can satisfy a paging
  condition on the first scrape. The manifest is merged and the diff pre-verified.
- **Rolling v3.123.0 to prod** — the owner's call. The image exists; nothing deploys
  automatically.
- [#422](https://github.com/noetl/ai-meta/issues/422) — the reader shipped. The `/metrics`
  gauge would be **invisible until #410 lands**, and replay/discard needs a payload-scrub
  design, not an endpoint.
- [#406](https://github.com/noetl/ai-meta/issues/406) — an accepted upstream wait.
  `quick-xml` needs a crypto-backend decision; `rsa` has no patched release. **3 is the
  expected RustSec reading**, not a regression.
- [#234](https://github.com/noetl/ai-meta/issues/234) — **do not sweep.** One remaining
  reference is a working dependency: the travel Maps secret exists only in the old
  project.
- [#235](https://github.com/noetl/ai-meta/issues/235) — the disposition of a frozen column
  is an owner decision.
- [#380](https://github.com/noetl/ai-meta/issues/380) — blocked on noetl/docs#188 merging.

## Waiting on the owner

`noetl/noetl` enforces an approving review with admin enforcement, so these cannot be
self-merged. All green.

**All three `noetl/noetl` PRs are merged** (#707, #708, #709) — `main` is `e18e50d2`, three
workflows green. Nothing is waiting on a review right now.

One prod action remains, deliberately not taken:

- [#410](https://github.com/noetl/ai-meta/issues/410) — apply the fixed `PodMonitoring`.
  The manifest fix is merged ([ops#321](https://github.com/noetl/ops/pull/321)); applying it
  resumes a scrape that has been dark for 25 days, which can satisfy a paging condition on the
  first scrape. Choosing the hour is the owner's call.

## Open, tracked

| Issue | State |
| :-- | :-- |
| [#410](https://github.com/noetl/ai-meta/issues/410) | manifest fixed, prod apply pending (above) |
| [#422](https://github.com/noetl/ai-meta/issues/422) | reader **landed** (`GET /api/internal/events/dead-letter`, v3.123.0, metadata only). Still open: a `/metrics` gauge, and replay/discard. **Build the rest before arming `NOETL_MATERIALIZER_DEAD_LETTER`** |
| [#406](https://github.com/noetl/ai-meta/issues/406) | accepted upstream wait — `quick-xml` ×2 + `rsa`/Marvin. **Not a blocker.** A current published lock reads **3**, and that is the expected number |
| [#360](https://github.com/noetl/ai-meta/issues/360) | reopened; acceptance box 6 un-ticked 2026-10-04 because the green was measured over a window shorter than the mechanism's period |
| [#234](https://github.com/noetl/ai-meta/issues/234) | ⚠ **do not sweep.** One remaining reference is a *working* dependency on the old project — the travel Maps secret exists only there |

## Shipped this arc

Closed: #361, #374, #375, #378, #385, #390, #395, #398, #400, #402, #415.

- **PyPI `noetl` 5.1.1** published and verified on the artifact — 4 files sha256-matched,
  shipped lock byte-identical to the repo's, RustSec **5 → 3** with the previous release's lock
  scanned first as a positive control.
- **Clippy gates on all 5 Rust repos**, allow-lists 23 → 2, and **all 7 Rust repos pin 1.99.0**.
- **PR gates for ops / e2e / apt**, plus a daily sweep over all **15** wikis (243 md files).
- **apt arm64 built every release** (2.8.7 → 5.0.3 newest arm64); orphaned `.deb`s 22 of 23 → 0 of 26.

## The drift audit is worth reading again

`playbooks/drift-audit.sh` output went **160 DRIFT lines → 9** on 2026-10-04. It was not that 151
things got fixed: the `inert-tests` section was **94% of the output at 0% signal** (150 vendored
crates, and its one first-party hit was text inside a string literal). It is now worth reading, so
read it.

What remains, and why each is still there:

| finding | state |
| :-- | :-- |
| 2 × stale project refs (#234) | one is **load-bearing** — do not sweep |
| `noetl.execution` frozen (#235) | disposition is an owner decision |
| server pod unscraped (#410) | manifest fixed, prod apply held |
| 3 × pinned sets NO-GUARD (#415) | deliberately visible, not excluded |
| `schema_ddl.sql` differs | fixed by noetl/noetl#709, awaiting review |
| 3 × pinned sets NO-GUARD | **cleared** — guards landed (noetl/server#493), now 0 |

## ⚠ Never run `cargo fmt` across noetl/server

`tests/auth_gate_wiring.rs` searches `main.rs` for the literal `.merge(<name>.layer(`.
rustfmt splits those merges across lines, so one `cargo fmt` makes **12 privileged
routers read as ungated** and the guard goes red. It happened on 2026-10-05, and it is
the **second** time rustfmt has blinded a text-scanning guard in that crate.

`main.rs` carries a comment saying so. `main` also already has **139 fmt diff sites**
across 39 files and CI does not gate fmt, so a repo-wide format is never a small change
there. Format only the files you touched, and quote the site count before and after.

## ⚠ Before the next release of any Rust submodule

Two things bit on 2026-10-05 and both are cheap to avoid:

- **Never put a closing keyword + a cross-repo issue in a submodule commit body.**
  `Closes noetl/ai-meta#NN` fails `@semantic-release/github` **after** the tag is cut
  and **before** `release.yml` is dispatched, so the version is tagged and released
  with **no image** and nothing says so. Use `Refs`, and close from ai-meta. GitHub's
  own cross-repo close works — the plugin's does not. See
  `agents/rules/commit-conventions.md`.
- **A `ci:`/`chore:` run going green says nothing about the image build.** Those
  commit types release nothing, so `release.yml` never runs. The server image was
  broken for two days behind a wall of green `ci:` merges. After any change to a
  Dockerfile, a toolchain pin, or a base image, build the affected stage locally
  (`podman build --target <stage>`) rather than waiting for the next `fix:`.

## Standing cautions for whoever picks this up

- **A green over nothing is a failure.** Every check here prints the population it measured.
  Several "clean" results this arc were a scan that examined zero things.
- **Read the rate, not the total.** A large denominator over a short window is not a result —
  see #360.
- **Diff the whole object before any prod apply**, never the field you changed
  (`agents/rules/apply-safety.md`). That is what caught ops#321 nearly dropping two pods from
  monitoring while fixing something else.
- **A count over the wrong population is the commonest false clean.** Four times on 2026-10-04 a
  measurement of mine was wrong before it was right: a scan that examined 0 files and said `OK`, a
  red-main count that read a 6-run window instead of the latest run per workflow, an alert blast
  radius of "0 of 19" from a filter that matched nothing, and a pytest proof that ran no tests.
  Every one was caught by printing the denominator.
- **A Ready pod proves nothing about what a startup step did.** `ensure_table` swallows
  every error and returns `Ok(())`, so prod's dead-letter table had to be established
  from the *absence* of a warning — with a filter control, because an empty log search
  and a broken log search look identical.
- ⚠ **Prod's server is v3.122.0** (digest `919bc70c`, rolled 2026-10-01). My notes said
  v3.112.7 for three weeks and I reasoned from it. Read the version from the pod
  digest or `*_build_info`, never from a written-down number.
- **A closing keyword in prose closes the issue.** `closed #400` inside a heading shut #400 on
  merge; see `agents/rules/commit-conventions.md` for the detector.
