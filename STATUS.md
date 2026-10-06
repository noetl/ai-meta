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

## 🟢 PROD: the chain-store gates are ARMED — disarmed 18:36Z, RE-ARMED 19:23Z on evidence

**Net state = the original baseline.** `NOETL_CHAIN_POPULATE=true`,
`NOETL_CHAIN_ADVANCE=true`, `NOETL_CHAIN_SOURCE=chain`; env **67**; generation **56**;
revision `7c97b8df`; image **unchanged** throughout at `49eb47fc` (v3.123.2).
ops#323 restores the as-built (ops#322 was the disarm).

⚠ **Two prod rolls happened, and the second was mine to own.** I disarmed at 18:36:35Z under
an explicit approval, then the decision rule became *"disarm only if it is blocking
progress."* Applying that test gave **NO**, so the prescribed state was armed, and I restored
it at 19:23:33Z. Both rolls were env-only, image never moved, and the only collateral was
**exactly 2 heartbeat-failure WARNs per worker — one per roll — each self-healed on the next
beat**.

### The "is it blocking?" test, leg by leg

| leg | finding |
| :-- | :-- |
| the mechanism that made arming unsafe | **[#362](https://github.com/noetl/ai-meta/issues/362) is CLOSED** — an event committing into the *middle* of an `ORDER BY event_id` read, because a snowflake id is minted before the insert. Fixed in ehdb **v0.4.5** (`order_by_links`, mutation **5/5**) + server#477 |
| durable verdict | 2026-09-30 re-ramp **GREEN over 8h 28m**, spanning ~8 divergence cycles: coverage **278**, divergence **0**, refusals 1 (`dangling_prev`), multi_root/no_root/fork/unreachable **0** |
| measured again today | armed pod over **3h55m**: extended=50, in_sync=1, opened=1, diverged=**0**, fork=**0**, multiple_roots=**0**, stale_log=**0**, one_root=1088; divergence **0** across 16 series; refusals **0** across 10; ERROR **0** |
| #360 | still open, but about **false** divergence in the comparator — not corruption of the chain |
| catalog interference | **none.** `noetl/catalog` owns datasets `c1`–`c4` under its own caller-supplied root; every "chain" mention in its source is a doc comment, zero code paths |
| deploys | v3.123.2 rolled fine earlier this session **with the gates armed** |

**Conclusion: not blocking, working, failing safe.** Disarming mid-flight would remove a
measured-good capability for no stated benefit — the riskier move of the two.

### What the disarm window did establish (worth keeping)

- ⚠ **Absent is the correct off, not `0`.** The three off-states are *different shapes*: the
  booleans are an allow-list `matches!("1"|"true"|"yes"|"on")`, while `SOURCE` is a `match`
  whose `_ => None` is a fail-safe for **unrecognised** values. A blanket `0` reads off only by
  landing in those fail-safe branches, never as a declared default.
- ⚠⚠ **Never (dis)arm by applying the ops manifest.** It pins image **v3.118.0** while prod
  runs v3.123.2, and a server-side apply **conflicts on `.image`** with field manager
  `kubectl-set` — it would roll the image *backward*, into the known-wrong `event_id` ordering
  the manifest's own header warns about. Use a targeted JSON patch: `test` ops asserting each
  name at its index, `remove` in **descending** index order, dry run diffed **whole-object**
  (expect exactly 6 changed leaf paths, every survivor byte-identical).
- ⚠ **Either direction needs a positive control.** The patch touches `spec.template`, so the
  pod rolls and every counter resets — `chain_populate_total = 0` is *also* what an idle new
  pod shows. The cleanest discriminator found: an **armed** boot logs `event-chain DDL
  skipped` warns as the chain path initialises, where a **disarmed** pod logs **zero** chain
  lines at all. Config itself reads straight out of the process:
  `kubectl exec … -- env | grep "^NOETL_CHAIN_"`.
- ⚠ **Honest limit on the re-arm verification.** `chain_populate` has not moved since 19:23Z,
  and that is explained rather than worrying: `chain_head_hydrate` is **0 across all
  outcomes**, i.e. **no execution has advanced** on the new pod, so there is nothing to
  populate. Worker logs confirm sparse traffic (last execution 19:20:04Z, previous 16:20:35Z).
  The functional proof that this exact config populates is the pre-disarm pod: extended=50
  over 3h55m. I did not drive a synthetic execution to force the counter.

### ⚠ What the two rolls actually cost: one in-flight mirror batch each

Found by not accepting a clean-looking reading. ~30 min after the re-arm, eventlog cross-store
divergence had gone from **0 of 130** (armed pod, 3h55m, before any roll) to **3 of 24**
(12.5%) — and it was climbing. It is **not** a chain-gate effect; the chain counters are clean.
Reading the pair of counters identifies it exactly:

```
eventlog_mirror_attempt_total{outcome="unavailable"}   2      <- pinned, == two rolls
crossstore_divergence_total{kind="count",tier=eventlog}  1 -> 2 -> 3   (climbing)
eventlog_mirror_queue_total{outcome="drained"}        188 -> 262        (healthy)
mirror lag p100 < 2.5s over 188 samples; pending_mirror 0
```

**Two in-flight batches were lost, one per roll**, when the relay was unavailable during
restart. That left a **permanent count deficit**, and the comparator **re-reports the same
deficit on every sampling pass** — so `divergent` grows with no new loss.

⚠ **The reading hazard:** `divergent` climbing while `unavailable` is flat looks like a
worsening leak and is actually a fixed deficit counted repeatedly, because the counter counts
*comparisons* rather than *distinct diverged executions*. The discriminator is the pair, never
`divergent` alone.

This generalises past my two rolls — a release, a config change or an autoscaler event would
each do it. The implied fix is a **graceful-shutdown drain** (the mirror abandons its queue,
where `L0Engine::drop` joins its uploader). `NOETL_EHDB_MIRROR_REPAIR_SWEEP=true` is set and did
not close the gap within ~40 min. Recorded with the full measurement on
[#343](https://github.com/noetl/ai-meta/issues/343); disposition is a design call, not mine.

**Unaffected:** the chain machinery being toggled — `extended` climbing 6 → 9 with `diverged`,
`fork`, `multiple_roots`, `stale_log`, `length_disagreement`, `no_root` all **0**;
`one_root=1088`; ERROR 0; pod 1/1, restarts 0.

### Rollback (to disarmed), if it is ever wanted

```bash
PROD=gke_shastaratech-noetl-prod_us-central1_noetl-prod-autopilot
kubectl --context "$PROD" -n noetl patch sts noetl-server-rust-embedded --type=json -p '[
 {"op":"test","path":"/spec/template/spec/containers/0/env/66/name","value":"NOETL_CHAIN_SOURCE"},
 {"op":"remove","path":"/spec/template/spec/containers/0/env/66"},
 {"op":"test","path":"/spec/template/spec/containers/0/env/65/name","value":"NOETL_CHAIN_ADVANCE"},
 {"op":"remove","path":"/spec/template/spec/containers/0/env/65"},
 {"op":"test","path":"/spec/template/spec/containers/0/env/64/name","value":"NOETL_CHAIN_POPULATE"},
 {"op":"remove","path":"/spec/template/spec/containers/0/env/64"}]'
```

Also recorded inline in the ops manifest, so neither direction needs archaeology.

## Catalog — both reverse indexes, and no fifth dataset

[catalog#13](https://github.com/noetl/catalog/pull/13) + [#14](https://github.com/noetl/catalog/pull/14),
merged on green. **109 tests**, fmt + `clippy -D warnings` clean, **AC3 still exactly 4 `Dataset`
impls**.

Two queries the model could not answer: *"every resource using credential X"* (the one that
matters when rotating a keychain alias) and *"every resource of type X"* — `catalog list` printed
*"a full path listing needs an index this store does not yet keep"*. A fifth dataset answers both
and breaks AC3, so each index lives **inside an existing dataset** as a second row kind:

| dataset | forward key | synthetic key | answers |
| :-- | :-- | :-- | :-- |
| `c3` | `path` | `\u{1}attr/<name>` | `resources_with_attribute` |
| `c1` | `path` | `\u{1}type/<kind>` | `resources_of_type` |

Sound because `ehdb-l0` matches the index key by **exact string equality** (`engine.rs:1489`). The
sentinels are **control characters** — a path reading `attr/uses_tool.postgres` would otherwise
silently answer a reverse query — and a forward write intruding on either space is **refused**,
because a path comes from a document and is untrusted input.

### ⚠⚠ The RED was never a zero

| index | with `.last()` planted |
| :-- | :-- |
| c3 | `uses_credential.adiona_actor: 1 path(s), expected 49` |
| c3 after an unset | `0 path(s), expected 48` |
| c1 | `playbook: 1 path(s), expected 53` |

**Partial, returned successfully.** The middle row was unpredicted and is the worst: once any
resource unsets the attribute, the latest op under the shared key is a **tombstone**, so `.last()`
reports *"nobody uses this credential"* while 48 do — which would green-light a rotation that
breaks all 48. Every assertion is **set equality**; a count of 49 can still be the wrong 49. In
both PRs 2 of 5 tests passed under the RED, correctly — they do not exercise the fold.

### Verified against ground truth derived independently from git

```text
git truth adiona_actor:   49   catalog: 49   SET EQUALITY, byte for byte
git truth adiona_migrator: 4   catalog:  4   SET EQUALITY, byte for byte
union 53, intersection 0 · uses_tool.postgres 53 · nonexistent attr 0
list --type playbook -> 53 · --type Playbook -> 53 (case-insensitive)
```

### Three bugs of my own, each caught by a test rather than review

1. **The tombstone that was never written.** Archiving a *version* is not archiving the *path* —
   v1 archived with v2, v3 live must stay listed. I got that right and the **type-name lookup**
   wrong: it read from `versions()`, which folds latest-op-per-version and emits only
   `Registered`, so once every version was archived it returned an **empty vec**, the fallback
   returned early, and no tombstone was written. The path stayed listed forever — the same
   under-reporting the function exists to prevent, by the opposite route.
2. **`partition()` derived from `r.path`** would send a reader to the **wrong shard**, returning
   *nothing* rather than erroring. Both datasets now derive it from `index_key()` so they cannot
   disagree.
3. **Synthetic rows in a forward fold** are excluded from the **input**, not the output: a reverse
   row's `name()` equals a real attribute name and would **shadow** it — a wrong value, not a
   missing one.

Also closed a self-contradiction: ingest left `resource_type("playbook")` as `None` while
`resources_of_type("playbook")` returned all 53, so the CLI printed *"type playbook is not
declared in this store"* above a successful listing of 53. Ingest now declares on first use.

**Cost, stated:** 2× the row count in both datasets (106 logical attributes → 212 `c3` rows;
40 KiB against `c1`'s 148 KiB). The alternative is 53 indexed reads today, ~1,600 at expected
size.

**Scope, measured not assumed:** a `kind:` sweep across travel/noetl/ops finds 183 `Playbook`
plus `Deployment`/`Service`/`ConfigMap`/`ScaledObject`/`Namespace`/`Secret`/`PVC`/`VMRule` —
**Kubernetes manifests, not NoETL internal resources**, so out of scope. No third NoETL resource
type exists in the tree to add, so "a second resource type" is already satisfied by
`subscription` (catalog#7).

### Next catalog phase, by evidence — NOT out of work

1. **Relations against a corpus that has them.** The adiona 53 are leaf playbooks calling no
   child, so `relations=0` is correct there and the relation path has **never been exercised on
   real data**. The 36 registered `muno/*` playbooks do call children — that is the corpus with a
   real denominator.
2. **Observability.** `Ticked { sealed, merged, reclaimed }` and `Ingested { scanned, registered,
   skipped }` are returned and recorded nowhere. Per `observability.md` the three artefacts ship
   with the change, and reclaim especially needs to be visible — its absence was the silent cost
   catalog#11 fixed.

## Catalog — reclaim, and a driver that made the rest reachable

Both merged on green: [catalog#11](https://github.com/noetl/catalog/pull/11),
[catalog#12](https://github.com/noetl/catalog/pull/12). 99 tests, fmt + `clippy -D warnings`
clean. [#427](https://github.com/noetl/ai-meta/issues/427).

**#11 — the merge driver was doubling disk.** The previous phase proved the part count fell
25 → 4. It did, and bytes rose 42% in the same tick, because the test measured the number the
fix was about.

| | before | after |
| :-- | :-- | :-- |
| live parts | 4 | 4 |
| `tick()` | `merged=3 reclaimed=0` | `merged=3 reclaimed=48` |
| part files | 49 → 56 | 49 → **8** |
| bytes | 94,784 → **189,568** (2.00x) | 94,784 → 96,736 (1.02x) |

54 part files and substrate objects for **4 live parts**. `reclaim_orphans` is caller-owned
and documented as deleting "the superseded source parts a merge leaves behind", so driving
merges without it was a trade rather than a fix — reporting success either way. The prod-PVC
shape.

⚠ The test's byte assertion was **wrong on first draft while the code was right**: it
expected a merge to *shrink* storage. A merge consolidates parts holding the same records, so
bytes are flat by construction; the property that discriminates is that bytes must not
**grow**.

**All five caller-owned EHDB lifecycle calls are now accounted for** — three driven, two
deliberately not, with reasons on `tick`'s doc comment:

| call | status |
| :-- | :-- |
| `seal_aged_parts` | driven by `tick()` |
| `run_pending_merges` | driven by `tick()` |
| `reclaim_orphans` | driven by `tick()`, **after** the merges — the manifest swap is what makes sources unreferenced, so reclaiming first finds nothing and reports a healthy 0 |
| `apply_retention` | **never.** Drops whole parts below a floor; the catalog folds latest-op-wins over *every* op, so a resource whose only `Registered` op fell below the floor vanishes from `latest()` while its later attribute ops survive |
| `flush_and_wait_uploads` | **not needed.** `L0Engine::drop` joins the uploader, whose `while let Ok(job) = rx.recv()` drains the queue before seeing the disconnect (`ehdb-l0` `engine.rs:654` / `:1701`) |

**#12 — nothing could run any of it.** Three library crates, **zero binaries**, and `tick()`
/ `register_from_source` had **0 non-test call sites**: 89 tests passed and the catalog had
never seen a real document. `tick`'s own doc comment says it must run on a timer; nothing
called it once.

The new `catalog` binary reads a **git ref, not the working tree** — a population sweep on
*this repo* reported `adiona yaml: 0` while `origin/main` carries **53**, the checkout being
41 commits behind on a side branch. A bad ref now errors rather than returning an empty
listing, since an empty listing satisfies "0 skipped" and reads as a clean run.

First real run over the 53: `scanned=53 registered=53 skipped=0 relations=0 attributes=0`.

* `relations=0` is **correct** — leaf playbooks calling no child. ⚠ A first regex claimed 53
  of 53 carried a child reference; it was matching each document's own `metadata.path`.
* `attributes=0` was a gap: a playbook yielded nothing because `find_attributes` read only
  `metadata.labels`, and none of the 53 have labels. All 53 carry a tool kind (53x postgres)
  and an auth alias (**49x `adiona_actor`, 4x `adiona_migrator`**).

Now `uses_tool.<kind>` + `uses_credential.<alias>` → **attributes=106**, exactly 53 x 2, the
four migrator playbooks cross-checked against ground truth derived independently from git.
`uses_credential` is the one with teeth: rotating `adiona_actor` means knowing the 49
playbooks that break.

⚠⚠ **The alias only, never a value.** A scalar `auth:` is a reference the keychain resolves;
a **mapping** is an inline credential, and copying it would duplicate a secret into a second
store. Skipped — and mutation-tested, not trusted: the relaxed check fails the test with the
leak in its own output, `uses_credential.Mapping {"password": String("hunter2")}`. 1 of 5
tests caught it.

**Next, by evidence:** `uses_credential` is half its value without the reverse lookup. "Every
resource using alias X" needs a per-path `show` today, because the four datasets index
attributes by *entity*. ⚠ A fifth dataset would violate AC3 (a test pins the `Dataset` impl
count at exactly 4), so the answer is a secondary index key inside `c3`.

## adiona/frontend triage — COMPLETE, 8 of 8, zero frontend code touched

| # | classification | action |
| :-- | :-- | :-- |
| **59** | **backend-fixed** | travel#133 (`1e20a68313`) — `read_only` flag, read arc ahead of the save arc, 31-check guard, new `playbook-tests.yml` CI. Comment corrects the framing: `merge: true` already existed, partial update already worked, the gap was the **read path**, and merging `{}` is not data loss |
| **55** | **ambiguous — blocked on product** | 22 scenarios inventoried from the three `.docx` (51,603 chars): F1–F10, D1–D5/D7–D9, H1–H4. Blocked on **D6 being absent** (numbering jumps D5→D7), **three divergent canonical-slot vocabularies**, and **no combined-trip document existing** |
| **5** | **backend — deployment gap, NOT actioned** | **53** `adiona/v1/*` playbooks exist on `travel@origin/main`, **0 registered** on the catalog the SPA reads, while **36** `muno/*` are. Needs `auth: adiona_actor` + the `adiona.*` schema. A prod catalog change — the owner's call |
| **4** | **split** | UI frontend-only; data half blocks on the #5 decision. Beach Tours / Cultural Programs are **the same query with a different category value** |
| **2** | **backend already provides it** | `system_prompt_extraction.md` + `extract_turn`'s persisted `slot_state`. ⚠ A second client-side parser must agree on every sentence forever; the first divergence presents as a backend bug |
| **3** | frontend-only | Not actioned. Flagged that 28 widget-contract schemas already define the card shape, incl. `loading_card` / `error_card` |
| **51** | frontend-only | Not actioned (styling). Flagged the vocabulary divergence, since a flight form and a hotel form built to their own docs will not line up |
| **6** | frontend-only | Not actioned. Checked for a backend content source — there is **none** |

⚠ A false zero in my own verification: the coverage check filtered comments by
`user.login == "Kadyapam"` (the git user *name*) and reported `mine=0` on all eight while I
held eight comment URLs. The API login is lowercase. Trusting it would have double-posted
every comment.

## 🔴 The three stale server PRs are still OPEN — closing them would discard live work

[server#480](https://github.com/noetl/server/pull/480),
[#473](https://github.com/noetl/server/pull/473),
[#481](https://github.com/noetl/server/pull/481). My staleness measurements were **wrong**:

* **#473's premise is live.** Two byte-exact `== "true"` sites (`ehdb_embedded.rs:49`,
  `ehdb_projection_fold.rs:1655`), a third spelling accepting `"enabled"`
  (`ehdb_eventlog_mirror.rs`), two duplicated `env_bool`, and no shared `truthy()`. I had
  grepped only `main.rs` and generalised to a 14-file PR.
* **#481's benchmark is the only record of its conclusion** (0 matches in #367, 0 org search
  hits) and its spec #366 is open.
* **#480's `examples/chain_cert_bench.rs` is unique to it.**

Instead the evidence was made durable on
[ai-meta#367](https://github.com/noetl/ai-meta/issues/367) and as a correction on #473 —
including a correctness hazard recorded nowhere else: rolling up by commit batch is
boundary-dependent, so two replicas that batched differently produce different digests for
the same chain. **Disposition needs the owner.**

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
