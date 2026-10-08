# STATUS — present tense

Last refreshed: **2026-10-08** (EHDB audit + measures)

---

## 📐 EHDB: audited, and measured for the first time

### The audit — EHDB is not stubbed, it was UNMEASURED

| probe | result |
| :-- | :-- |
| `todo!` / `unimplemented!` / `TODO` / `FIXME` / `XXX` | **0** across 177 `.rs` files — positive-controlled (the same grep finds 979 `pub fn`), so the zero is real |
| tests | **1120** `#[test]`/`#[tokio::test]` across 81 files; baseline green |
| every `stub` hit | a **deliberate negative control** (`Backend::Stub` exists so the conformance suite can be shown to reject it) |
| ⚠ **benchmarks** | **`ehdb-l0` — the engine on the production path — 88 `.rs` files, ZERO bench files.** `ehdb-reference`, the *reference model*, had 22 files and **two**. **82% of the workspace unbenchmarked.** |

⚠ **Three of my own recollections were wrong and the audit corrected them:** a
`ProjectionDriver` trait **does** exist; `fold_latest_by` is the *catalog's* helper, not
EHDB's; and **`single root` has zero mentions in EHDB at all** — that invariant lives in the
server, not here.

### The measures (ehdb#381, wiki `3b98c70`, doc `docs/measures/l0-benchmarks.md`)

**Result 1 — the fsync is ~95% of posture-A write cost.**

| path | records/s | µs/record |
| :-- | --: | --: |
| posture A (`EveryAppend`) | **267** | 3749 |
| group commit, batch 8 | **1 010** | 990 |
| group commit, batch 80 | **5 450** | 184 |

**20.4x.** ⚠ Group commit needs `FlushPolicy::CallerDriven`; without it batching costs
*more*.

⭐ **Independently corroborated.** The existing wiki page measured `ehdb-reference` at
"~3.9 ms → ~256 appends/s"; the production engine measures **3.749 ms → 267/s** — within
**4%**, different crate, different harness.

**Result 2 — a read steps 15.6x per record at `seal_max_records = 1024`.**

| records on one key | time | ns/record |
| --: | --: | --: |
| 900 | 49.1 µs | **54.6** |
| 1 100 | 933.8 µs | **848.9** |
| 4 400 | 3.760 ms | 854.6 |

A **22% length increase costs 19x**, then per-record cost is **flat** — a one-time step, not
quadratic. **A chain over 1024 events costs ~13x what sub-1024 extrapolation predicts.**
[#453](https://github.com/noetl/ai-meta/issues/453), where whether the step is *acceptable*
is an open judgement call.

**Invariant measures** — ordering, fold determinism, reopen parity — each with a **planted
defect**: a reversed read must flag every pair and one swap exactly one; the fold must change
on one swap *and* one dropped record, or determinism over it is vacuous; reopen parity must
fail on **one** missing element. Each prints its population.

### ⚠⚠ Three of three append instruments were wrong before they were right

1. `iter_batched` rebuilt the engine per batch → setup dominated, 8.3 ms/append. Caught by
   its **own control failing**: a 10x payload came out *faster*, CIs overlapping.
2. `iter_custom` fixed it; 267/s looked implausible until the engine's own docs confirmed
   `fsync-per-append, posture A` at "~4 ms". **The number was right.**
3. Group commit read **flat** (192 → 184/s over a 10x batch) because I left posture
   `EveryAppend` on. **The instrument was wrong, not the engine** — I nearly published
   "EHDB's batching does not amortise".

A timing measure written as a `cargo test` was **removed**, not relaxed: debug builds put a
~100 µs floor under it, so a 10x step cost 1.4x and it failed its own control. The reason is
recorded in the file.

### Named as NOT measured

**p99** (criterion gives mean/median, not tails) · **memory** · **seal/merge/reclaim cost**
(the merge path grew a prod manifest quadratically on 2026-09-01) · **multi-shard and
concurrent writers** — every figure is single-shard, single-threaded · **`ehdb-feed`**, 36
files, still 0 benches.

## ✅ The catalog is now DEPLOYABLE, and the business catalog can be WRITTEN

### 1. `catalog-server` deployability — it ran nowhere

157 tests, an HTTP acceptance suite, and **no Dockerfile and no release workflow**.

| | |
| :-- | :-- |
| Dockerfile | `rust:1.99.0-alpine`, the *same* version `rust-toolchain.toml` pins; `git` in the builder for the `noetl/ehdb@v0.4.5` git deps — ✅ **verified public and resolvable UNAUTHENTICATED**, the way a runner sees it, so no credentials |
| cache safety | dependency layer, then `find -exec touch` before the real build, so a stale mtime cannot ship **the dummy binary**; `test -s` asserts the artifact at build time |
| runtime | carries **`curl`** (four `build_info lines=0` readings in August were a missing HTTP client, not a missing metric) and **`git`** (for `ingest` from a `git:<repo>@<ref>` source). **No HEALTHCHECK** — k8s probes live in the Deployment |
| ⚠ volume | the store is on disk and declared a `VOLUME`; without a mount the catalog **resets on restart**, which looks like an empty catalog |
| CI gate | image built on **every PR** and then **RUN** — binary >1 MB, carries the route strings, a real token-guarded write read back through the reverse index, unauthenticated write refused. *A build-only check passes for an image that cannot start.* |
| release | tag-triggered, **native per-arch** runners, manifest list, and it **asserts ≥2 architectures** — amd64-only is how server#303 was found late |
| version | `verify-version` takes the **tag**, never asserts `tag == Cargo.toml` (that assertion *is* the 2026-08-03 regression); `ci/stamp-version.sh` re-stamps, rewrites exactly one line, RED-proven to fail on a `v` prefix and on a no-op |

**Proof:** image builds (**29.8 MB** arm64 local, amd64 in CI), binary **6,609,520 B**
local / **6,668,896 B** in CI, container serves `/health`, `/types` and **10 `catalog_`
series**, **14 HTTP checks through the image** (custom type, register, attribute, relation,
list-all, both reverse indexes, DELETE, tick) 0 failed, survives `podman restart`, and a
**fresh volume reads 0** — the negative control proving persistence was the volume.
catalog#27.

⚠ **No image is published yet** and nothing is rolled: that needs a release tag, which
needs catalog#28 (below).

### 2. The business catalog WRITE path, proven against the LIVE project

`travel/playbooks/catalog/items/upsert` writes items, localized content, images, units and
the category hierarchy in **one `batch_write`**. travel#140.

The load-bearing part is the **ancestor closure**: Firestore has no recursive query, so
"every item under Beach" is one `array-contains` only if the whole path is materialised at
**write** time. An item on a leaf not findable from the root is the failure, and it is
silent.

**⚠⚠ A live write found a defect no fixture could.** The first run rejected **all 24
documents**: Firestore paths **alternate** collection/document, so a document path needs an
**even** segment count. `catalog/items/itm_x` is 3 — a *collection* reference.
`catalog/items` is 2 — a *document*. **The read playbook had the same defect and had never
been caught, because it had never been EXECUTED against Firestore**; the design doc
specified it too. Root is now `catalog/v1` (4 / 3 segments). The guard asserts path arity.

**Live proof** — pre-state verified (`catalog` absent):

- write: `expected 24 / written 24 / counts_agree true / provider_error null`
- what landed: **set-equality EXACT**, 24 of 24, against an expectation computed from the
  fixture *independently of the playbook*
- read back, **42 checks 0 failed**: `cat_root` → all **3** published items *none of which
  sit directly on root*; `cat_beach` 2; `cat_city` 1; leaf+`de` → "Strandhotel Malaga";
  `ka` → "მალაგას სანაპირო" with items lacking `ka` falling back to `en` and
  **`lang_is_fallback: true`**; nonexistent category → empty; the `draft` item written and
  excluded everywhere
- ⚠ three of those checks first read FAIL — **my harness**, not the playbook: a deep search
  for `items` found an intermediate list with no `name`
- **prod restored**: all 24 deleted children-first, collections back to
  `['chat_threads','users']`, **0** under `catalog/`

### 🔴 Flags

| item | state |
| :-- | :-- |
| **catalog#28** (`semantic-release` must not push to `main`) | ⚠ **BLOCKED — no CI run has ever been dispatched for it.** The branch is pushed and matches the PR head; Actions works elsewhere (travel fired at 00:24:35Z), so this is catalog-repo-specific. The required check cannot pass, so the fix for GH006 cannot merge, so **no release can be cut**. Needs an admin look at that repo's Actions. |
| first catalog release | failed **GH006** — `@semantic-release/git` pushing a `[skip ci]` commit to a protected branch can never be accepted. Fixed in #28, which is blocked. ⚠ noetl/server's own `release.yml` carries this exact warning and I reproduced it anyway. |
| ⚠ a bot-pushed tag does **not** trigger workflows | would have tagged a version and built **no image**, all green. Dispatch step added in #28. |
| **server v3.123.3 prod roll** | released, prod runs **3.123.2** — the 53 adiona playbooks stay unrunnable until it lands. **Owner's call.** |
| `attribute_schema` | still fully inert. **Wire-or-delete is the owner's call.** |

⚠ **I reported an "org-wide Actions outage" and was wrong** — travel had simply had no
pushes. Corrected by checking a repo that *had* just been pushed.

catalog#27 · travel#140 · catalog#28 (blocked)

## 🔴 NEGATION PASS — what "done" was not, and what now closes it

Adversarial sweep over everything claimed complete. The read paths survived; the write
and removal surface did not.

### Survived the negation (genuinely done)

Proved by **set equality against git/Firestore ground truth**, on real data — 67
playbooks, 140 attributes ingested over the API:

| query shape | result |
| :-- | :-- |
| reverse attribute index (`uses_credential.adiona_actor`) | **49/49 set-equal**, `adiona_migrator` 4/4 |
| by-type (`?type=playbook`) | **67/67 set-equal** vs an independent git count |
| forward relations | **7/7 set-equal** |
| reverse relations | **7/7 set-equal** |
| auth (503 unconfigured / 403 wrong token / open reads) | correct |
| metrics | **not inert** — `sealed` 0→4, ingest 67→74, positive control passes |
| ingest denominator | `scanned=71 registered=67 skipped=4`, and 67 matches an independent count of files with a top-level `kind:` |

⚠ Two of my own probes read `0` against a working API because I guessed the response
keys (`relations`/`target_path` instead of `edges`/`to_path`, then `callers`/`from_path`).
**The envelope differs between the forward and reverse endpoints**, which is how it
caught me twice.

### 🔴 Falsified — seven store methods had ZERO callers outside their own tests

`archive` · `restore` · `unset_attribute` · `unset_localized_attribute` ·
`retract_relation` · `attributes_in` · `languages_of`

The capability was built and **no endpoint reached it**. So:

| # | falsified claim | now |
| :-- | :-- | :-- |
| 1 | "full CRUD" — there was **no DELETE or UPDATE verb anywhere**; all six probes returned 405 | `DELETE /objects`, `POST /restore`, `DELETE /attributes`, `DELETE /relations`, all **soft** |
| 2 | `GET /types` could only ever report noetl's **six** — a custom declared type was invisible, and the test asserting `declared == known` **passed vacuously** | enumerated via a `TYPE_REGISTRY_KEY` sentinel in the existing `c4` dataset; **still no fifth Dataset (AC3)** |
| 3 | `GET /objects` **required** `type`, so "what is in this catalog" was unanswerable | `type` optional, walks every declared type |
| 4 | every store error was **HTTP 500** — a bogus tool kind and a wrong value type both 500'd | caller errors are **400** |
| 5 | the API **could not write a localized attribute at all** — `SetAttribute` had no `lang`, so `languages_of` answered `[]` whatever was written | `lang` on the write path; `?lang=` on the read |
| 6 | a value sent in the shape it is **read** in was stored **double-wrapped** as `json` | tagged form parsed first |

### 🔴 Falsified — "53 adiona playbooks registered" said nothing about runnable

`POST /api/execute {"path":"adiona/v1/catalog_list"}` → **400**,
`data did not match any variant of untagged enum ToolDefinition`.

Cause: `ToolSpec.params` was `HashMap<String,Value>` — **map-only** — and these bind `$1`
positionally. ⚠ **The dispatcher always wanted an array and the server was the only
objector**: `noetl-tools` `tools/postgres.rs:29` is `pub params: Vec<serde_json::Value>`,
its own test uses `[42]`, `duckdb.rs` uses `[1,"hello"]`, and **only `http.rs` uses a
map**. Same defect `command` already had and was fixed for. Fixed in server#498,
**released as v3.123.3**.

### Proof discipline

Catalog: **157 tests, 0 fail**; **7 mutants, 7 caught**; **20 HTTP checks against real
ingested data** asserting set equality — archiving shrinks the live set by *exactly one*,
unsetting one credential attribute takes the reverse index **49 → 48 (not → 0)**,
retracting one edge leaves the *other three* callers.

⚠⚠ **My first mutation battery ran against a RED baseline** — a repo guard
(`every_rust_source_on_disk_is_git_tracked`) had correctly caught my new test file being
untracked — so all seven readings were worthless and were re-run after the baseline was
green. One mutant first read SURVIVED because **the mutant itself was malformed**; redone
rather than reported.

Server: RED was a **runtime** failure, not a compile error — the test bodies go through
`serde_json::to_value` so they compile against the old type. 2 of 3 failed with the exact
production message while the map case passed, so the test discriminates.

### ⚠ Gaps found and deliberately NOT closed

| gap | why |
| :-- | :-- |
| **Prod roll of server v3.123.3** | the 53 adiona playbooks stay unrunnable in prod until it lands — prod is **3.123.2**. A deployment, so the owner's call. |
| `catalog-server` has **no Dockerfile and no release workflow** | it is deployed nowhere; that is also why the breaking response-shape change is safe now |
| `attribute_schema` is still **fully inert** | declared, has a builder, set in one test, read by nothing. Wire it as per-type validation or delete it — a design decision, not a bug fix |
| business catalog has **no write path** and no domain round-trip | nothing has ever been written to `catalog/items` in Firestore; only `items/list` was ever proven |
| forward/reverse response envelopes differ (`edges`/`to_path` vs `callers`/`from_path`) | cosmetic, but it defeated my own probe twice |

catalog#26 · server#498 (v3.123.3)

## ✅✅✅ Three prod items completed — and SIX defects in one playbook, all reading as "empty"

### 1. `calendar/list` re-registered against the LIVE project — v1 → v6

| # | defect | PR |
| :-- | :-- | :-- |
| 1 | `kind: agent` — not one of the 25 `ToolKind` variants; in the reject list | travel#135 |
| 2 | `gcp_project: noetl-demo-19700101` — retired, Firestore frozen since 2026-08-09 | travel#135 |
| 3 | **no step named `start`** — rejected at parse time (`src/playbook/parser.rs:184`) | travel#136 |
| 4 | render read fields at the top level; they live under `data` → **0 of 12** survived | travel#137 |
| 5 | `{{ step.result }}` resolves to **nothing** — read a child by the **bare step name** | travel#138 |
| 6 | no `return_result` → the dispatch was **async**; step got `{"status":"started"}` | travel#139 |

⚠⚠ **#3 fires BEFORE tool-kind validation, so it masked #1.** My earlier report that the
tool-kind fix made the playbook runnable was **wrong** — only executing it showed that.

⚠⚠ **#2 is why none of it was noticed.** A wrong GCP project returns an **empty
collection, not a 404**, so a single symptom covered five causes and never looked like a
bug.

⚠ **#6 was invisible to a 29-check guard.** That guard execs each step's embedded `code:`;
the bodies were correct and only the *declaration* was wrong. **A guard over step bodies
is structurally unable to see a whole-step or whole-workflow rule.** Three new checks are
structural over the YAML.

**Proof** — same thread, same registered playbook, only `gcp_project` differing:

| run | `gcp_project` | `event_count` | `documents_returned` |
| :-- | :-- | --: | --: |
| live | `shastaratech-noetl-prod` | **12** | **12** |
| control | `noetl-demo-19700101` | **0** | **0** |

Firestore holds exactly **12** documents at
`chat_threads/chat-mtalhs7m-78hi4c/trip/current/events`. The live number is right and the
control shows the discriminator works.

### 2. Six Firestore composite indexes deployed

Baseline **0** → **6, all `READY`**, **set-equality exact** against
`firestore.indexes.json`. `firebase` CLI is absent so `gcloud firestore indexes composite
create` was used; the account holds `roles/owner`, so no permission blocker. Index
creation blocks on the build, so it ran as a background job.

### 3. All 53 `adiona/*` playbooks registered

**53/53 set-equality**, all **v1**, **0 rows removed**. Audited first: 53/53 parse, 53
distinct paths, **only `kind: postgres`**, **all have a `start` step**, and **no GCP
project pins** — they reach external Postgres by keychain alias (`adiona_actor` ×49,
`adiona_migrator` ×4), so the Firestore project does not apply to them. Catalog 1395 →
1453; the **+58 reconciles exactly** as 53 adiona + the 5 `calendar/list` versions.

⚠ Execution of these still depends on `adiona_actor` / `adiona_migrator` existing in the
keychain — I did not touch credentials, and 4 of the 53 are **migrator** playbooks, now
runnable by anyone who can execute. Reversible via `POST /api/catalog/delete` (soft).

### ⚠ My own measurements that were wrong first

- **Prod server is v3.123.2**, not the v3.122.0 this file claimed.
- I printed `registered=53, failed=0` and "non-success: 53" in the same breath — my filter
  looked for `"success"` when the status word is `"registered"`.
- Two probes returned a confident empty: a mistyped scratchpad path, and `cargo` missing
  from the `PATH` I exported.
- `mk() {…}` refused (alias) and `$K get pods` did not word-split — two zsh traps already
  in the index, hit again.

The port-forward carried every prod reading, and the **negative control confirmed it**:
killing the forward killed the probe.

travel#135–#139 · travel wiki `84b8cc5` · ai-meta wiki `8032387`

## ⭐⭐ The travel BUSINESS catalog is Firestore — and three silent defects on the way

The other half of the two-catalog split, built where it belongs.

| | **internal catalog** | **business catalog** |
| :-- | :-- | :-- |
| holds | NoETL's own objects | items, categories, attributes, images, bundles, reservations |
| storage | **EHDB only** | **Firestore** — this domain's choice |
| interface | `/api/catalog/*` | a **playbook step** under its policy block |

### Audit first: the connector already existed

`automation/agents/mcp/firestore`, registered **v11**, 904 lines, **ten tools**
(`get_doc` `set_doc` `delete_doc` `query_collection` `append_event` `replay_events`
`batch_get_docs` `batch_set_docs` `batch_append_events` `batch_write`), Firestore
**REST v1**, **Workload Identity / ADC** — no key, no secret, nothing in the keychain.

**No `firestore` tool kind exists and none was needed.** The 25 `ToolKind` variants
include `Gcs` (Cloud Storage), not Firestore. Four limits, read off the *registered*
implementation rather than its docstrings ([#451](https://github.com/noetl/ai-meta/issues/451)):
AND-only `where` over `= < <= > >= array-contains`; built **without** `allDescendants`
so **no collection-group queries**; `limit` capped at 500 with **no cursor**;
`delete_doc` does not recurse.

### ⚠ A hypothesis of mine that the data refuted

I reasoned to a **read/write project split-brain** — inline read on
`shastaratech-noetl-prod`, MCP write on `noetl-demo-19700101` — and checked instead of
publishing. Refuted: `slot_state` is live in `shastaratech-noetl-prod` to **2026-09-30**
and frozen in `noetl-demo-19700101` since **2026-08-09**; both paths use the live one.

The check found the real shape. **Registered** says `shastaratech-noetl-prod`; **git**
said `noetl-demo-19700101`. Re-registering from git would have caused two silent
failures at once:

1. **Repointed the whole business catalog at a project frozen two months ago.** ⚠⚠ Both
   projects hold a `(default)` database and a `chat_threads` collection, so the wrong
   project returns an **empty collection, not a 404** — and the planner treats an empty
   `slot_state` read as *"a brand-new thread… not an error"*. Every conversation would
   have looked new. **The defect is actively disguised by correct 404-tolerance in the
   consumer.**
2. **Dropped half of every turn's writes.** `batch_write`'s `set_docs_extra` /
   `append_events_extra` — which `persist_all_atomically` depends on — are absent from
   the git copy, and absent keys are **ignored silently, not rejected**.

Third defect: travel's `playbooks/catalog/calendar/list`, **registered in prod as v1**,
declared **`kind: agent`** — in the server's explicit reject list, so it could never
run — *and* pinned the dead project. travel#134.

### ⚠ Zero composite Firestore indexes are deployed

And the travel repo had **no index declaration file at all** — `firestore.rules` governs
client access and says nothing about indexes. Every query in the new model needs one.
`firestore.indexes.json` declares six; applying it is a prerequisite, not a side effect
of the merge.

### The model: structural borrowing, restated for a document store

A recursive CTE becomes a **materialised ancestor array** (`items.category_ids`,
`categories.ancestor_ids`) queried with one `array-contains`. Localization becomes
`items/{id}/content/{lang_code}` where the **document id is the language**, so a
localized read is a `get_doc` at a computed path. `attrs` is a map, so Firestore
auto-indexes `attrs.<key>` and the EAV rows arrive with the parent.

⚠⚠ **Firestore enforces no referential integrity.** `nullable` and cardinality are
advisory; **`on_delete: cascade` must be written as playbook steps**, because
`delete_doc` deliberately does not recurse and an orphaned subcollection is invisible to
every query under its deleted parent while still billed and readable by path. Soft
delete preferred, matching `POST /api/catalog/restore`.

### Verification

`scripts/business_catalog_items_test.py` — **29 checks**, the playbook's own embedded
code, no network, no credentials. A **RED control** feeds `query_collection`'s
`documents` key to a `batch_get_docs` reply (the exact wrong shape my first draft used),
because that bug yields an **empty join** that is indistinguishable from "no item has a
translation". **4 of 4 injected mutants caught**; green baseline after restore, so the
4/4 is not a red-baseline artifact. Verified **running**, not merely present:
`guards discovered: 6 … guards run: 6 failed: 0`.

⚠ **Three of my own measurements were wrong first.** The `ops` checkout was **28 commits
behind `origin/main`**; the `travel` checkout was on a **feature branch with no `adiona/`
at all** (0 paths vs 93 on `origin/main`); and two probes returned a confident empty —
one from a mistyped scratchpad path, one because `cargo` was not on the `PATH` I
exported. All three are the stale-checkout / false-zero families already in the index,
hit again in one session.

travel#135 · ops#324 · travel#134 closed · wikis `a28d21e` + `537f3d6` · ai-meta@6ea4025

## ⭐⭐ TWO CATALOGS — the line, and a bleed found in my own fixtures

"Catalog" names two different concerns, and conflating them is the mistake worth designing
against.

| | **internal catalog** — `noetl/catalog` | **business catalog** — NOT that repo |
| :-- | :-- | :-- |
| holds | noetl's own objects: `playbook`, `credential`, `mcp`, `agent`, `memory`, `subscription` | domain data: hotels, flights, trips, items, categories, translations |
| storage | **EHDB only.** No external datastore, ever. | **Anything** — external Postgres, a third-party API, an object store |
| interface | `/api/catalog/*` (API-only, no SQL) | a **playbook step**, under that playbook's policy block |
| scales with | how many things noetl knows about | how much domain data a tenant has |

> **The internal catalog holds the playbook that reads the business data. It never holds the
> business data.**

### ⚠ The bleed was in my own test fixtures

Two files modelled **business entities as internal objects**. I wrote both:

| file | held | now |
| :-- | :-- | :-- |
| `foreign_key_identity.rs` | `table_row` + `categories/10`, `category_types/1`, `trip_category/1`, `trips/100` — adiona business rows | `playbook → mcp` and `playbook → credential` (`muno/playbooks/profile`, `automation/agents/mcp/firestore`, `credential/adiona_actor`) |
| `localization.rs` | `resource_type: "category"` + `category_name` in en/de/ka — adiona's categories *and* their translations | `resource_type: "memory"`, `memory/notes/welcome`, `display_name` |

Nothing in the store enforced this — a resource type is a free string by design, which is
why the generality works. **A fixture is where the intended use gets taught**, so a business
entity in a fixture is the bleed, even with no code change behind it.

⚠ **My first re-audit had a bad denominator** and I published it. It scanned one idiom —
`resource_type: "x"` — found 15 literals, and reported the resource types as *playbook (13),
subscription (1), memory (1)*. There are **three** idioms. Adding the helper constructors
(`ent(..)`, `eref(..)`) and `ResourceType::` literals takes the population to **46**, and the
set to **six**: `playbook`, `subscription`, `memory`, `credential`, `mcp`, `agent` — the
narrow scan had missed three of the six entirely, including both halves of the FK fixture it
was supposed to be checking. All six are real internal types, so the conclusion held; the
measurement did not.

I also claimed **no business entity name appears anywhere**, which is false as written. The
honest form, by data vs prose:

| name | total | prose/comment | **as data** |
| :-- | --: | --: | --: |
| `categories` | 4 | 4 | **0** |
| `category_type` | 3 | 3 | **0** |
| `trip_category` | 2 | 2 | **0** |
| `table_row` | 1 | 1 | **0** |
| `item_content` | 1 | 1 | **0** |

**Zero as data** is the claim that matters, and it holds. The 11 mentions are doc-comments
recording where the structural ideas came from — including the one I added saying what the
fixture used to hold — which is provenance worth keeping, not bleed. Two further greps were
substring artifacts of my own making: 9 of 14 `trips` hits are `round_trips`, and every
`flights` hit is the **playbook name** `muno/playbooks/flights-details`, an internal object
that happens to be about flights.

### Localization is the sharpest case

It was built citing adiona's **24 `_translate` / `_content` tables** — which are **business**
tables. `adiona.item_content` carries `lang_code` in **external Postgres**, read by
`adiona/playbooks/catalog_list.yaml` through `kind: postgres` + `auth: adiona_actor`. So the
evidence for localization is entirely business-side: **no internal object type has a
demonstrated need for it.** The `lang` dimension stays because it is already built, tested
and **inert** — it is not built on further, and it is now documented as such.

### The business catalog already exists — documented, not designed

Measured in `noetl/travel`: **53** `adiona/playbooks/*.yaml` reach the external `adiona.*`
schema through `kind: postgres` + `auth: adiona_actor`; flights, hotels, places and documents
go through `mcp/duffel` (3), `mcp/hotelbeds` (2), `mcp/google-places` (3), `mcp/firestore` (3).

That is exactly what `execution-model.md` already mandates: a data touch inside a playbook
step, credential by keychain alias, server API for `noetl.*`. **The business catalog *is*
that pattern** — there is no component to build and nothing to migrate.

### Why adiona was only ever inspiration

Because **adiona *is* a business catalog**, so its relational model already lives on the
business side. What the internal catalog took was structural, not schematic: one polymorphic
identity instead of a table per entity type, the EAV collapse, the self-referencing taxonomy,
the typed value union. Its tables were never the target — which is why there is no DDL parser
and why acceptance is set-equality over noetl's own objects.

`catalog#25` (`0e34865`), 152 tests, fmt + clippy clean. travel#72 corrected the same way:
the model *as an object* is plausibly internal; the **weights are neither catalog** (object
store, with a catalog row holding the reference); and **training data drawn from the domain
is business data that must not be pushed into EHDB**.

⚠ `repos/catalog` was never registered as a submodule, so there was no pointer to bump —
registered in this change set as the 34th.

## adiona/frontend triage — COMPLETE, 8 of 8 open issues, zero frontend code touched

Constraint honoured: **no edit, push or PR in `adiona/frontend` or any UI codebase.** Every
finding was either fixed in the backend or left as a comment.

| # | title | classification | action |
| :-- | :-- | :-- | :-- |
| **59** | Need update to profile playbook | **backend-fixed** | travel#133 merged (`1e20a68313`) — `read_only` flag + read arc ahead of the save arc, 31-check guard, new `playbook-tests.yml` CI. Comment corrects the issue's framing: `merge: true` already existed, partial update already worked, the gap was the **read path**, and merging `{}` is not data loss. |
| **55** | Create routing/Q.A. playbook | **ambiguous — blocked on product** | Deliverables 1+5 done from the three `.docx` (51,603 chars): **22 scenarios** — F1–F10 flights, D1–D5/D7–D9 discovery, H1–H4 hotels. Raised 5 open questions; **blocked on 1 (D6 absent — numbering jumps D5→D7), 2a (three divergent canonical-slot vocabularies), 4 (no combined-trip document exists)**. |
| **5** | Populate Category Content | **backend — deployment gap, not actioned** | Not a frontend bug and not a missing feature: **53** `adiona/v1/*` playbooks exist in `noetl/travel/adiona/playbooks/`, **0 registered** on the catalog the SPA reads, while **36** `muno/*` are. They need `auth: adiona_actor` + the `adiona.*` schema. Two options stated; deliberately did **not** register them — that is a prod catalog change and the owner's call. |
| **4** | Add Category Sections Post-Search | **split** | UI frontend-only (not actioned); the data half blocks on the same #5 decision. Mapped the five sections to `category_type` values and noted Beach Tours / Cultural Programs are **the same query with a different category value** — making the section list data would stop this recurring. |
| **2** | Implement Input for Trip Preferences | **backend already provides it** | `playbooks/agent/system_prompt_extraction.md` is a full NL slot-extraction contract at `temperature: 0` with JSON mode; `itinerary-planner.yaml`'s `extract_turn` persists `slot_state` across turns. ⚠ A second client-side parser would have to agree with it on every sentence forever; the first divergence presents as a backend bug. Frontend work is "post text, render widgets". |
| **3** | Build Recommendation Display Section | **frontend-only** | Not actioned. Flagged that the data contract already exists — 28 widget-contract schemas incl. `place_card`, `place_list`, `activity_list`, plus `loading_card` / `error_card`, the states a grid gets retrofitted badly without. |
| **51** | Design fix to FlightIntakeForm | **frontend-only** | Not actioned (pure styling). Flagged the #55 2a vocabulary divergence, since a flight form built to the flights doc will not line up with a hotel form built to the hotels doc. |
| **6** | Implement Navigation Links | **frontend-only** | Not actioned. Checked for a backend content source and there is **none** — the catalog holds playbooks and widget schemas, no CMS-style store — so the copy cannot come from us. |

⚠ **A false zero in my own verification pass.** My coverage check filtered comments by
`user.login=="Kadyapam"` (the git user name) and reported **`mine=0` on all eight issues**
while holding eight comment URLs. The API login is lowercase `kadyapam`. Had I trusted it I
would have double-posted all eight. The contradiction between the filter and the URLs is what
caught it — a case-sensitive identity filter is a clean-looking zero.

⚠ Reconciliation after the earlier API timeout found **zero** comments had posted, so there
was no partial state to repair; the only pre-existing comment anywhere was `@grozina`'s 2025
image on #2.

## 🔴 The three server PRs are NOT closed — my earlier assessment was wrong

Asked to close #480/#473/#481 as superseded "per your own measurements". Two of those
measurements were mine and wrong, so closing would have discarded live work.

| PR | stated premise | measured |
| :-- | :-- | :-- |
| **#473** | premise gone | ⚠ **LIVE** — 2 byte-exact `== "true"` sites remain (`ehdb_embedded.rs:49`, `ehdb_projection_fold.rs:1655`), a 3rd spelling accepts `"enabled"`, 2 duplicated `env_bool` helpers, no shared `truthy()` |
| **#481** | work shipped | ⚠ its benchmark is the **only** record of its conclusion — 0 matches in #367, 0 org-wide search hits; spec #366 still **open** |
| **#480** | superseded | library part **yes**; `examples/chain_cert_bench.rs` is **unique to the PR** |

My "#473 premise gone" came from grepping **only `main.rs`** and generalising to a 14-file
PR. I never checked #480/#481's example files.

**Instead of closing, I made the evidence durable** so closing is safe later:

- Posted #481's full findings to **#367** — the verdict (batching recovers 12%), the
  decomposition, the denominator-sensitivity table, and ⚠⚠ a **correctness hazard recorded
  nowhere else**: rolling up by *commit batch* is boundary-dependent, so two replicas that
  batched differently produce **different digests for the same chain**.
- Posted a correction to **#473** so nobody closes it on my earlier wrong claim, including
  that `NOETL_EHDB_PROJECTION_SERVE_ON_BEHIND` is read by a byte-exact site — works today
  at `"true"`, silently OFF at `"True"`.

Both need a rebase, and #473's conflict is in `src/main.rs`, the one file that must not be
edited mechanically (`auth_gate_wiring` text-scans it). **Their disposition is yours.**

---

## Catalog: two defects found by auditing against EHDB's contract

Both in my own code, both found by reading the contract rather than by a failing test.

**1. `op_seq` restarted on reopen** (`catalog#9`). Appended *below* the existing maximum,
violating *"ascending `sort_key` within a partition"* **without erroring** — and it returns
a **wrong answer**: a post-reopen write was ordered before the one it supersedes
(`"dev"` where `"prod"` was written later). Fixed with EHDB's own
`append_writer_assigned`; the hand-rolled counter **deleted, not patched**.

**2. Merges were never driven** (`catalog#10`). ⚠ My first hypothesis was **wrong**: 3,500
records gave 3 parts and `run_pending_merges()` performed **0**, because `MergePolicy::d1`
needs 4 consecutive **durable** small parts (~4,096 ops at the default). So harmless today
— but the **attribute** log will cross it. With the driver: **25 parts → 4**, all 200
versions intact. `tick()` now returns `Ticked { sealed, merged }` because `merged: 0` is the
*normal* reading and one total would make a healthy store and a broken driver identical.

**88 tests.** Pointer bumps `ai-meta#437`, `#438`.

---

## 🟢 v3.123.2 LIVE ON PROD — both fixes verified

| | |
| :-- | :-- |
| **Running** | `noetl_server_build_info{version="3.123.2"} 1` — the binary's own report |
| **Digest** | `49eb47fc0f1e5ce38bc8884e21e3eb29614042890806d7b33a9dc60188956fb2` |
| **Rollback** | `091ff47f…` (v3.123.0) — recorded, unused |
| **Revision** | `5f6cffb8ff` → `559f688dff`, generation 53 → 54 |
| **Health** | `restarts=0 ready=true` 1/1, **0** panic/fatal/ERROR lines (control: 31 log lines read) |
| **Env** | **67 before and after**; `POPULATE`/`SOURCE`/`ADVANCE` **untouched**, as instructed |

Range check before rolling: **2 files changed, both catalog, 0 touching the chain path**
(control: 121 tree-wide), identical `NOETL_CHAIN_*` read-set at both tags.

### #429 verified — both casings now agree

| request | before | after |
| :-- | --: | --: |
| `resource_type: "playbook"` | 650 | **1525** |
| `resource_type: "Playbook"` | 875 | **1525** |
| `resource_type: "PLAYBOOK"` | — | **1525** |
| `resource_type: "Mcp"` | 0 | **2** |

Arithmetic closes: 1525 playbooks + 2 mcp = 1527 unfiltered.

### #432 verified — with four controls

A list-form bogus tool kind is now **rejected**, and the message names **`step 't1'`** —
the *tool item's own name*, which only the new sequence arm supplies. The old walker
collected nothing and would have **accepted** it.

| control | result |
| :-- | :-- |
| positive (right pod?) | `build_info{version="3.123.2"}`, `/api/health` 200 |
| mapping-form (worked before) | rejected naming `step 's'` — the *step* name |
| discrimination | missing metadata → a **different** message, so not blanket-rejecting |
| negative (kill the forward) | HTTP **000** — the probe really went through it |

No catalog rows were written; all probe registrations were rejected.

### ⚠ Latency: a +33% reading that dissolved under like-for-like measurement

A post-roll window read emit **143.4 ms** against a 108.1 ms "baseline" — but the
baseline was a 30-min window and the **adjacent 17-min pre-roll window has zero
traffic**, so no like-for-like comparator existed. An equal-length window *earlier* reads
**177.0 ms**, worse than post-roll. The diff is 2 catalog files with **0** on the
event-emit path.

So: variance on sparse bursty traffic, not a regression. ⚠ The honest limit is that prod
traffic here is too sparse to support a tight latency claim in **either** direction.

---

## ⭐ Latest phase: `subscription` as a real second resource type

`catalog#7` → `5d7f90c2`, pointer bumped via `ai-meta#435`. **83 tests.**

The generalization claim stops being structural and becomes **measured**. AC3 previously
proved *"adding a type adds no `Dataset` impl"* with a synthetic `widget`; it now proves
it with a **live** type that shares nothing structurally with a playbook.

| | playbook | subscription |
| :-- | :-- | :-- |
| content | a `workflow:` tree | a `spec:`, **no `workflow:` at all** |
| reference location | `workflow[].tool[].path` | `spec.dispatch.playbook` — **9 of 9** fixtures |
| credential dependency | — | `spec.auth` (6 of 9) → `RelationKind::Requires` |

Discovered from the codebase, not invented: 9 `kind: Subscription` fixtures plus **2 rows
on prod**. The playbooks they dispatch (`sub_ingest_default`, `handle_webhook`) sit in the
same fixture directory, so the cross-type graph is **closed and checkable**.

**⭐ Zero datasets added — AC3's count is still exactly 4.** RED-proven by planting a
`c5_mcp_entity` dataset: the exact regression AC3 exists to catch, and the one that looks
most reasonable in isolation (*"mcp needs its own shape"*).

**⭐ `RelationKind::Requires` finally has a real use.** `spec.auth` names a **credential**
— a type the catalog deliberately does *not* hold, since the CLI diverts credentials to
`noetl.credential`. The edge is recorded anyway: a dangling dependency is worth knowing
about even when the target lives elsewhere.

### ⚠ Two API shapes that would each have passed a naive test

- `FoundReference` hardcoded `Invokes` and `"playbook"`, which would have made the
  credential dependency **unreadable while still producing a plausible edge count of 2**.
- Attribute scalar typing puts **bool before integer before string**: a string fallback
  placed first captures everything and makes every attribute `Text`, which still
  round-trips.

### ⚠ A false-green shape caught live

While waiting on `ai-meta#435`, seven consecutive polls read
`mergeStateStatus=CLEAN, checks=0` — no checks had been *created* yet. An empty match set
satisfies "all checks completed". The `not rs` arm is what kept the loop going; gating on
"nothing is pending" alone would have merged on a green that did not exist.

---

## Earlier phases this run — one-line index

| what | where | state |
| :-- | :-- | :-- |
| **catalog P3 — relation extractor** | `catalog#5` → `210cf35c` | ✅ merged, 62 tests |
| **extract→store loop closed** | `catalog#6` → `7f848d7b` | ✅ merged, **67 tests** |
| **list-form tool-kind defect** | `server#497` → **v3.123.2**, image in AR | ✅ **#432 closed** |
| pointer bumps | `ai-meta#433`, `#434` | ✅ merged |
| wikis (ai-meta ×3 pages, server) | pushed | ✅ |
| **#410 closed** | applied + scraping cleanly | ✅ |

### ⚠⚠ A measurement caution — read this before trusting a `drift-audit.sh` run here

The ai-meta **primary** working tree is **~98 commits behind main** with stale submodule
checkouts: `repos/server` is **24 files** behind its `origin/main`, `repos/noetl` **54
lines**. So audit findings taken from this environment are claims about *the tree*, not
about the system.

It cost real time this session. Three layers:

1. The **local `drift-audit.sh` is 143 lines shorter** than main's, with **0** `vendor`
   mentions vs main's **6** — so it predates the #413 vendor exclusion *and* the #425
   preflight. Every `vendor/` finding it reported was its own known noise.
2. ⚠ **A preflight that ships inside the thing being checked cannot report that the
   thing is stale.** The stale script has no preflight, so nothing warned me.
3. Running main's version with a symlinked root made the preflight say *"NO submodule
   tree is readable (0 of 0)"* while the checks demonstrably read real trees (192
   first-party `.rs` in server, 11,798 vendored excluded). **The per-check denominators
   are what settled it**, not the preflight.

Concretely: `schema-copies` reported DRIFT. Comparing `origin/main` against
`origin/main` showed the two DDL bodies are **byte-identical at 54,260 bytes each** —
the difference was the stale local `noetl` copy missing the dead-letter block. **The
check is correct and was not changed.** Not "fixing" a correct check was the right call.

### The defect P3 uncovered, because it is the headline

`validate_tool_kinds` (ai-meta#256) read `tool:` as a **mapping only**. For the
**sequence** form the walker collected nothing — so the guard ran, returned
successfully, and **validated an empty set**.

| | files affected | kinds missed |
| :-- | --: | --: |
| before | **59 of 166** | **219 of 1,178** |
| after | 0 | **0 genuine** |

Shape distribution across the corpus: 20 sequence-only, 109 mapping-only, **37 using
both in one file**. Hand-verified on `test_vars_block.yaml` — five list-form blocks
each carrying `kind: python`, extracted **zero**. A typo'd kind in list form therefore
**registered cleanly** and failed only at step execution. RED-proven 2 of 2.

⚠ The probe's raw after-figure is **3**, all three my own heuristic counting
`kind: Playbook` inside an HTTP prompt string and two Python code strings — text in
string literals, not tool kinds.

### ⚠⚠ Two testing lessons from P3, both the dangerous kind

- **The negative control needed a second half.** "Zero references" is also what a
  reader that *cannot parse the list form* returns — exactly what the server's walker
  returned on that same file. The test now also asserts the five tools were *visited*.
- **The oracle was wrong before the code was.** The ground truth counted every
  document's own `kind: Playbook` + `metadata.path` as a **self-reference**, so it said
  2 where the extractor correctly said 1. The tempting move there is to "fix" the code
  until it agrees.

---

## Earlier this run

| what | where | state |
| :-- | :-- | :-- |
| v3.123.0 rolled to prod | `build_info{version="3.123.0"}` | ✅ verified |
| #410 PodMonitoring | prod | ✅ scraping, 0 targets down |
| **noetl/catalog created** | https://github.com/noetl/catalog | ✅ CI **4-of-4 RED-proven** |
| catalog design spec | `catalog#1` → `04a61caa` | ✅ merged |
| ai-meta submodule + linkedProjects | `ai-meta#428` → `3d8adf39` | ✅ merged |
| **catalog P1 — model types** | `catalog#2` → `e1aae6d8` | ✅ merged, 30 tests |
| staged wiki Home | `catalog#3` → `935100bd` | ✅ merged |
| **catalog P2 — EHDB datasets + folds** | `catalog#4` → `ef1895f1` | ✅ merged, **47 tests**, fold **RED-proven 3 ways** |
| **kind-filter partial-result bug** | `server#496` → `b15e56e0` | ✅ merged → **v3.123.1**, image in AR |
| pointer bumps (×4 pointers) | `ai-meta#430`, `#431` | ✅ merged, gate passed |
| wikis | ai-meta (5 pages) + server `static-guards` | ✅ pushed |
| issues | **#429 closed**, #427 In progress w/ progress comment | ✅ |

**Nothing is in flight.** v3.123.1 is released and its image is in AR but **not
deployed** — prod runs v3.123.0. Rolling it is a separate decision and nothing waits
on it.

### 🔴 One small thing needs a human

`noetl/catalog`'s wiki is **enabled** but its git repo does not exist until **one page
is saved in the web UI** — verified with a positive control (`server.wiki.git`
resolves, `catalog.wiki.git` returns `Repository not found`, `has_wiki: true`). The
page is staged at `docs/wiki/Home.md` with copy commands in `docs/wiki/README.md`.

---

## 🟢 Both prod actions COMPLETE and verified

### v3.123.0 rolled to prod

| | |
| :-- | :-- |
| **Running** | `noetl_server_build_info{version="3.123.0"} 1` — the binary's own self-report, not a note |
| **Digest** | `sha256:091ff47f30cfd3d209c229faece3cf4465e14f704e5a2823a3aa3f3710ed8e6c` |
| **Rollback** | `sha256:919bc70cf9b8d38c32be5ee22dffcc1a07823f6137bf4b9f2d8745320a6401cb` (v3.122.0) — recorded, unused |
| **Revision** | `7fd4c9bb4f` → `5f6cffb8ff`, generation 52 → 53 |
| **Health** | `restarts=0 ready=true`, 1/1, started 06:19:07Z. Sibling `deploy/noetl-server-rust` untouched at 0/0 |
| **Env** | **67 before and after**, chain trio unchanged — `set image` touched only the image field |

Baseline (windowed delta, not the cumulative total — a cumulative histogram's mean
is since-process-start and cannot see a regression): `worker_event_emit` **103.0 ms**
over n=201/30 min; `event_ingest` 121.5 ms over n=12. Traffic is light (~7 emits/min),
so a matched 30-minute window is the only honest comparison.

Startup log carries three WARN lines, all the known-benign "event-chain DDL skipped
— server role not table owner"; no ERROR, panic or fatal. (Read with `grep -a` —
ANSI colour codes make a naive `grep " ERROR "` a false zero.)

**Reader endpoint verified, with controls:**

| probe | result |
| :-- | :-- |
| `/api/health` (positive control) | **200 OK** — proves the probe works |
| `GET /api/internal/events/dead-letter` | **403 Forbidden** — internal-token gate enforced ✅ |
| `POST` same path | 403 — the pre-existing writer is gated too |
| `/api/internal/events/no-such-route` (negative control) | **404** — so the 403 is the *gate*, not a catch-all |

⚠ The first probe attempt used busybox `nc` and returned empty for *everything*,
including the control — a broken probe, not a rejected endpoint. `wget` works;
`curl` and `python3` are absent from the image. Correcting an earlier note of mine:
`wget` **is** present.

`dead_letter` lines on `/metrics`: **0** — confirms #422's remaining gauge is
genuinely unimplemented rather than merely unfired.

#### ⚠ One correction the user should see

The instruction said *"the chain-cert flag stays OFF."* Precisely: **`NOETL_CHAIN_CERT`
is unset — it is OFF**, and `set image` does not touch env, so the precondition held
as written. But **`NOETL_CHAIN_POPULATE=true`, `NOETL_CHAIN_SOURCE=chain`,
`NOETL_CHAIN_ADVANCE=true` are set** — re-armed on prod 2026-10-01 at 15:06:18Z by
`shastaratech@gmail.com` (audit log; matches the pod start time). My records had them
removed 2026-09-30 and never captured the re-arming. That is the #360 configuration,
currently **failing safe**: ~7 "refusing to populate, falling through to Postgres"
warnings in 13 h, 0 divergence hits, positive controls on the log search passing.

Rolling neither armed nor disarmed it. **Disarming is a separate call and still the
user's.**

I verified the chain path at hunk level before rolling, because of this: 5 of 23
changed files match `chain|parity|populate|advance|cert`, and **every hunk in them is
inside `mod tests`**; the `NOETL_CHAIN_*` read-set is identical at both tags.
⚠ Correcting myself — an earlier note claimed the range touched nothing chain-related,
asserted at file granularity and unverified at the time. It is verified now and it held.

### #410 PodMonitoring applied — scraping cleanly

`up{job="noetl-server"}` = **1**; `up{namespace="noetl"}` = 8 targets, **0 DOWN**;
680 samples. All six previously-blind families now report (parity 19 series,
divergence 16, control 24, mirror-queue 6, pending-events 1, publish-failed 5) —
**all 0, non-zero: 0**. Pod untouched, `restarts=0`.

**No pager noise, and none is possible at these values** — I read the conditions
rather than assuming: the comparator policy needs a rate ratio `> 0.5` over 1800 s
(evaluates to 0 at zero rates); divergence needs `increase > 0` / `> 2`, and increase
is 0.

Server-side apply hit a `.spec.selector` conflict with manager
`kubectl-client-side-apply`; I used plain client-side `kubectl apply -f` — the
matching tool — rather than `--force-conflicts`.

---

## 🟢 NEW: noetl/catalog created, CI RED-proven, spec landed

**Repo: https://github.com/noetl/catalog** — public, Apache-2.0, default `main`,
matching all 10 production Rust submodules.

| artefact | state |
| :-- | :-- |
| Scaffold + CI | `089c607`, CI **green on that sha** |
| Design spec | [`design/catalog-model.md`](https://github.com/noetl/catalog/blob/main/design/catalog-model.md) — merged via `noetl/catalog#1` → `04a61caa` |
| ai-meta submodule | merged via `noetl/ai-meta#428` → `3d8adf39`; pointer gate passed |
| Tracking issue | [noetl/ai-meta#427](https://github.com/noetl/ai-meta/issues/427), on board 3, status **In progress** (verified, not assumed) |
| Branch protection | required check `rust`, `strict=true`, **no required review** — identical to ehdb/server/worker. **Self-mergeable on green, so catalog PRs need no user batching.** |

### The CI gate is real — 4 of 4 RED-proven

`ai-meta` ran its whole life with zero CI and five repos carry `clippy … || true`
which gates nothing (#374). Every step here can fail the build; none is `|| true`.
Each was proven on a planted defect, then the tree restored clean:

| gate | planted defect | result |
| :-- | :-- | :-- |
| `cargo fmt --all --check` | unformatted fn | failed, exit 1 |
| `cargo clippy -- -D warnings` | `needless_return` | failed, exit 101 |
| `cargo test --workspace` | `assert_eq!(2+2, 5)` | failed, exit 101 |
| source hygiene | untracked `.rs` on disk | failed, exit 101 |

⚠ The hygiene guard fired correctly on its *first* run, before anything was
committed, by refusing to compare against an empty `git ls-files`. A scan that finds
nothing reports no violations and reads exactly like a healthy workspace.

### Three audit findings that reshaped the design

1. **An event-sourced catalog already exists in shadow.** `catalog_log.rs` writes
   `CatalogRecord` to `StoreTier::Catalog`; `catalog.registered`/`.archived`/
   `.restored` already exist; `CatalogRelation` is a pure fold **nothing calls on a
   read path**. 1,601 prod records. So this *finishes and generalizes* a named
   predecessor. ⚠ The RFCs those files cite do not exist on disk.
2. **`d7_catalog` already exists in `ehdb-l0`** and D1–D10 are all taken. The spec
   takes neither D7 nor D11, defining its own `c1..c4` namespace — `Dataset` is a
   public trait, the D-space belongs to ehdb, and D7's flat `path`-keyed shape is
   wrong for entity+relation+attribute.
3. **There is no `Projection`/`Fold` trait in EHDB** — 23 public traits, none a fold.
   The pattern folds `read_index_after(key,0).last()`, i.e. latest-wins. ⚠ Correct
   for the entity log, **silently wrong** for attributes/relations where many entries
   share an index key: a naive copy keeps one and looks fine. AC4 plants two
   attributes as a positive control.

### The generalization, in one line

adiona needs a **new table per entity type** (`item_attributes`, `trip_attributes`,
`trip_category`). One polymorphic identity `(resource_type, path, version)` replaces
that, so **adding a resource type is one appended row** — enforced by AC3, which
asserts the `Dataset` impl count does not change.

### Two EHDB hazards recorded in the spec

- `seal_max_age` defaults to `None` → the durability window is **unbounded in time**,
  and setting it is necessary but **not sufficient**: a timer must drive
  `seal_aged_parts()`. The catalog is almost always idle, which makes it the worst
  case, not a mild one.
- `manifest_retain = 0` is unbounded; that default produced 6,770 snapshots / 19.4 GB
  behind 71.8 MB of data on prod and stopped every append.

---

## 🔴 A live bug found in passing — worth its own fix

`/api/catalog/list` with `resource_type: "Playbook"` returns **zero rows**.
Registration lowercases `kind` unconditionally (`services/catalog.rs:80-84`); the
listing predicate binds the caller's string verbatim (`db/queries/catalog.rs:250`).
`"playbook"` works.

Live callers that send the capitalised form: `noetl catalog list Playbook` (the CLI's
own help text says `Playbook`), the gateway UI fixture, and the handler's own rustdoc.
`grep -rn "resource_type" server/tests/` → **0 matches**; no test covers it. The
subscription scan got it right (`WHERE LOWER(kind) = …`); the catalog listing did not.

Next: open a server issue + fix. It affects users today and should not wait for the
catalog project.

---

## Open, tracked

| # | what | state |
| :-- | :-- | :-- |
| **#427** | the catalog initiative | **In progress** — P0 done; P1 model types next |
| **#422** | `event_dead_letter` write-only | reader **now serving on prod**. Open for the `/metrics` gauge (unblocked by #410) and the replay/discard design |
| **#410** | server pod unscraped | ✅ applied, scraping cleanly — closeable |
| **#406** | quick-xml + rsa/Marvin | accepted upstream wait; **3 is the expected RustSec reading** |
| **#380** | re-bump `repos/docs` | waits on noetl/docs#188 |
| **#367** | chain-certified projections | measured, documented |

---

## Cautions that cost real time — do not relearn these

- **Never `cargo fmt --all` in `noetl/server`.** It sweeps ~39 unrelated files and
  turned `auth_gate_wiring` red (12 privileged routers read as ungated). `src/main.rs`
  must not be reformatted at all — `tests/auth_gate_wiring.rs` searches it for the
  literal `.merge(<name>.layer(`.
- **Read versions from the digest or `build_info`, never from git or a note.** On
  `noetl/server` the tag and committed `Cargo.toml` disagree by design.
- **The default kubectl context is PROD.** Every kind command needs `--context kind-noetl`.
- **zsh does not word-split** `$K` in `K="kubectl -n foo"; $K get …`, nor `set -- $p`.
  Both bit this session; the second made two successful merges look like failures.
  Use a function, and verify outcomes by re-reading state.
- **`2>/dev/null` manufactures false cleans** — a missing output directory read as an
  empty baseline.
- **A probe through a missing binary returns a confident zero.** busybox `nc` returned
  empty for the positive control too. `curl`/`python3` are absent from noetl images;
  `wget` is present.
- **Local submodule checkouts are stale.** Seven repos pin toolchain 1.99.0 on
  `origin/main` while the local trees showed 1.91.1 or none. Read `origin/main`.
- **Assert the extraction before asserting about it** — and print the denominator.
- **Read the rate, not the total. Volume is not duration.**
