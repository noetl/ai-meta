# Travel SLM + playbooks — consolidated implementation plan

- **Status:** Phase 0 (plan) complete. Phases 1–2 not started.
- **Source:** operator-supplied archive `SLM-20260814T173426Z-1-001.zip`
  (10 files; 7 `.docx` converted with [`docx2md.py`](docx2md.py), a stdlib
  `word/document.xml` reader — no pandoc/python-docx on this host).
- **Tracks:** [ai-meta#139](https://github.com/noetl/ai-meta/issues/139)
  (SLM platform umbrella) · [#140](https://github.com/noetl/ai-meta/issues/140)
  (Phase A — prove the framework on travel) ·
  [#153](https://github.com/noetl/ai-meta/issues/153) (shadow rollout).
- **Session date:** 2026-08-14.

This plan maps every archive document to a concrete deliverable and draws a
hard line between work that is determinate today and work that is blocked on
product ranking decisions. It also records five findings that change what
"implement the archive" means — each was established against the live prod
catalog or the running cluster, not by reading the documents.

---

## 1. Archive inventory → deliverable

| Archive file | Words | What it is | Deliverable | Phase |
| :-- | --: | :-- | :-- | :-- |
| `Restore flight playbook.md` | — (1,575 ln) | Full playbook YAML, markdown-escaped | Register `muno/playbooks/flight-planner` | 1a |
| `Hotel Playbook Test requirnments.md` | 151 | The exact hotel-card JSON shape | New HotelBeds card playbook | 1b |
| `TRAVEL_SLM_USE_CASES_AND_PROMPTS.md.docx` | 8,789 | 82-scenario catalog (A–O) + vocabularies | Seed JSONL + vocab/oracle extension | 2 |
| `Travel Domain SLM Training Prompt Format.docx` | 1,271 | Use-case-record schema + label taxonomy | Third role (`usecase`) contract + schema | 2 |
| `PRODUCT_OWNER_USE_CASE_PLAYBOOK.md.docx` | 1,707 | Scenario→corpus pipeline + gates | Dataset acceptance gates in `dataset_build` | 2 |
| `Copy of PRODUCT_INPUTS_REQUIRED.md.docx` | 1,374 | Product decisions not derivable from prompts | **The decision list in §5** — gates the render layer | blocked |
| `more prompts.docx.md` (×3 — identical) | 1,757 | Flight prompt→intent→action table (76 rows) | Already folded into the catalog (Appendix A) | 2 |

The three `more prompts` copies are byte-identical (`md5 c0431be9…`); the two
`Hotel Playbook Test requirnments` copies differ only by docx wrapping. The
catalog's Appendix A states it supersedes `more prompts` and carries all 76
rows forward, so that file contributes **no new scenarios** — only phrasings
already present as `user_prompts`.

---

## 2. Findings that change the work

### F1 — the flight playbook was never lost; it is catalog v41

The archive YAML, de-escaped and parsed, is **structurally identical** to
`muno/playbooks/itinerary-planner` **version 41**, which is still in the prod
catalog (`yaml.safe_load(archive) == yaml.safe_load(v41)` → `True`; the only
difference is 1-space vs 2-space indentation, which YAML does not distinguish).

Two consequences:

1. **The restore source is the catalog, not the document.** Registering the
   bytes of v41 removes all risk from my markdown de-escaping. The document
   only tells us *which* version to restore and what to call it.
2. **v41 is 26 versions behind live.** The planner is at **v67** in prod. v41
   predates the HotelBeds migration and still routes hotels through Amadeus —
   which v67's own description records as removed because "Amadeus dropped
   developer-API support". Restoring v41 *to the same path* would regress prod
   by 26 versions.

The rename to `flight-planner` is what makes this safe: it becomes a **new
catalog path**, leaving `muno/playbooks/itinerary-planner` v67 untouched.

| | archive / v41 | live v67 |
| :-- | :-- | :-- |
| lines | 1,089 (2-sp) | 4,789 |
| hotels via | `mcp/amadeus.search_hotels` | `mcp/hotelbeds.*` |
| tool branches | places, duffel-offers, amadeus-hotels, duffel-order | + hotels, hotel-book, activities, transfers, skip |
| persistence | 4 separate Firestore steps | one `persist_all_atomically` |

### F2 — ⚠ the instruction to repoint `gcp_project` is right for secrets and wrong for Firestore

The task says to correct `gcp_project: noetl-demo-19700101` to
`shastaratech-noetl-prod`. That is **half right**, and the wrong half is
irreversible. Established 2026-08-05 by before/after execution against the
live catalog ([#234](https://github.com/noetl/ai-meta/issues/234)):

| API | `shastaratech-noetl-prod` | `noetl-demo-19700101` |
| :-- | :-- | :-- |
| secretmanager | ✅ | ✅ |
| places / maps | ❌ | ✅ |
| firestore | ❌ | ✅ |
| aiplatform (Vertex) | ❌ | ✅ |

- **Secret reads → repoint to prod.** Proven: it repaired four MCP providers
  that were silently 403-ing.
- **Firestore / Places / Vertex → must stay on `noetl-demo-19700101`.** Prod
  cannot serve those APIs at all. In this playbook `gcp_project` selects
  *which Firestore database holds the thread data* — repointing it splits the
  data, and writes landing in the wrong database are not recovered by
  re-pinning the old version. `mcp/google-places` was already repointed once
  and rolled back for this reason.

So the correction in `flight-planner` is **per-reference**:

| Reference | Now | Action |
| :-- | :-- | :-- |
| `openai_secret_path: projects/1014428265962/…` | `1014428265962` **is** noetl-demo-19700101 | repoint to prod secret path |
| `anthropic_secret_path: projects/1014428265962/…` | same | repoint to prod secret path |
| `gcp_project: noetl-demo-19700101` (Firestore + Places) | old project | **leave as-is** |

⚠ Note the second trap: the project is referenced **by number**, so a search
for the project *ID* does not find these two lines.

This is also exactly what the parallel session is doing (see F5) — it is
repointing Duffel's *secret* reads to prod and leaving the rest alone.

### F3 — the SLM vocabulary has drifted from the live planner

`repos/travel/automation/mlops/slm/travel/slm.config.yaml` and `oracle.py`
both declare a 4-tool vocabulary including `mcp/amadeus.search_hotels`, and a
12-intent render list. The archive catalog §2 declares **7 tools** (HotelBeds
hotels/activities/transfers instead of Amadeus) and **16 render intents**.
The live v67 planner agrees with the archive, not with the SLM config.

This is the drift check the Product Owner playbook §8 calls for, and it is
failing today. Phase 2 must reconcile `slm.config.yaml` + `oracle.py` vocab
**before** generating any corpus rows, or every generated row cites a tool the
planner no longer has.

| | slm.config.yaml (today) | archive catalog §2 / live v67 |
| :-- | :-- | :-- |
| tools | 4 (incl. `mcp/amadeus.search_hotels`) | 7 (HotelBeds ×3, no Amadeus) |
| render intents | 12 | 16 (+`show_transfers`, `hotel_confirmation`, `show_activities`, `trip_map`) |

### F4 — prior SLM work is substantial; Phase 2 extends it

Already in `repos/travel/automation/mlops/slm/travel/`:

- `oracle.py` (641 lines) — `extract()`, `render()`, `run_turn()`, fixtures.
- `datasets/seed/travel_seed_turns.jsonl` — **45 turn rows**.
- Six built model versions (`v1_constrained`, `v2`, `v3`, `v4`, `v4b`,
  `improve_cand_001`).

The generic template pack exists in `repos/ops/automation/mlops/slm/`
(`dataset_build`, `dataset_build_distributed`, `eval`, `finetune`, `package`,
`registry`, `replay`).

⚠ **The seed row schema is per-turn, not per-role.** A row is
`{id, intent_label, event_type, event_payload, slot_state}` and `oracle.py`
derives *both* the extract and render labels from it. The Product Owner
playbook's "one row per prompt phrasing × role" describes the *expanded*
output, not the seed file. Phase 2 therefore emits seed rows in the existing
per-turn schema and lets the oracle fan out to roles — matching the installed
pipeline rather than introducing a second one.

### F5 — coordination boundary with the parallel travel session

Session `local_46d9207c` ("Diagnose travel project in GKE") is **running** and
has `repos/travel/playbooks/itinerary-planner.yaml` checked out dirty
(+14/−4). Its edits repoint Duffel secret reads from `noetl-demo-19700101` to
`shastaratech-noetl-prod` at four sites — consistent with F2.

Cross-session transcript search is unavailable from this session (remote
orchestrator), so coordination is by file boundary:

| Artifact | Owner |
| :-- | :-- |
| `repos/travel/playbooks/itinerary-planner.yaml` | **parallel session — do not touch** |
| catalog `muno/playbooks/itinerary-planner` (v67+) | **parallel session — do not register over** |
| `repos/travel/playbooks/flight-planner.yaml` (new) | this session |
| `repos/travel/playbooks/hotel-cards.yaml` (new) | this session |
| `automation/mlops/slm/travel/**` | this session |

No file is claimed by both. Because the rename gives Phase 1a a new catalog
path, the two sessions cannot collide in the catalog either.

---

## 3. Phase 1 — the two playbooks

### 1a. `flight-planner`

1. Take the **v41 bytes from the prod catalog** as the base (not the archive
   document — F1).
2. Rename: `metadata.name: muno_itinerary_planner` → `flight_planner`;
   `metadata.path: muno/playbooks/itinerary-planner` →
   `muno/playbooks/flight-planner`.
3. Apply the per-reference project correction from F2 (secrets → prod,
   Firestore/Places → unchanged).
4. Decide the Amadeus branch. v41's `call_amadeus_hotels` targets a provider
   whose developer API is dead. For a *flight* planner the branch is out of
   scope; the options are to drop it or leave it unreachable. **Recommendation:
   drop the branch and its routing arc**, and record it in the PR body — a
   dead branch that reports success is the failure mode #234 documented.
5. Commit to `repos/travel/playbooks/flight-planner.yaml`.
6. Validate on kind (`--context kind-noetl`, per
   `agents/rules/deployment-validation.md`), then register on prod and run a
   real flight-discovery execution to confirm it advances.

### 1b. HotelBeds card playbook

Return the exact card shape from `Hotel Playbook Test requirnments.md`. It
calls `automation/agents/mcp/hotelbeds` **v6** (live), which already holds the
credential by reference (GSM `hotelbeds-hotels-test`, read via Workload
Identity) — no new secret handling.

Field mapping from the provider's `_hotel_summary` + Content API:

| Card field | Source | Determinate? |
| :-- | :-- | :-- |
| `id`, `name` | `code`, `name` | ✅ |
| `stars` | `categoryCode` (`4EST` → 4) | ✅ |
| `bedType` | `roomName` of cheapest bookable rate | ✅ |
| `price`, `pricePerNight`, `totalPrice`, `nights` | `minRate` ÷ (checkOut−checkIn) | ✅ |
| `breakfastIncluded` | `boardName`/`boardCode` = `BB` | ✅ |
| `image` | Content API photo → GIATA CDN | ✅ |
| `location` | `destinationName` / `zoneName` | ✅ |
| `rating` | `reviews[].rate` | ✅ |
| `rooms[]` (`id/type/price/sleeps/refundable/image`) | `rooms[].rates[]`; `refundable` from `rateClass`≠`NRF` | ✅ |
| `amenities` | Content API `facilities` — **provider extension needed** | ✅ (work, not a decision) |
| `description` | Content API `description` | ✅ |
| `__renderDetailCard` | literal `true` | ✅ |
| **`ratingLabel`** | thresholds mapping 8.7 → "Excellent" | ⛔ **product** |
| **`category`** | bucket mapping → "Premium" | ⛔ **product** |
| **list order** | default hotel sort | ⛔ **product** |

Validation is against the HotelBeds **sandbox** (`api.test.hotelbeds.com`) —
the existing `_is_sandbox` gate stays on; no live booking.

---

## 4. Phase 2 — SLM corpus (determinate part)

1. **Reconcile vocab first** (F3): update `slm.config.yaml` + `oracle.py`
   `TOOL_VOCAB`/`RENDER_INTENT_VOCAB` to the archive catalog §2 (7 tools, 16
   intents). Without this every new row fails the drift gate.
2. **Expand the catalog to seed JSONL.** 82 scenarios; **71 live** (A–K + L1)
   and **11 roadmap** (L2–L6, M, N, O). Roadmap rows are generated but carry
   `eval_split: roadmap` and are **excluded from train/eval**, per the PO
   playbook §6 — they reference tools the planner does not have.
   Expanding `user_prompts` (3–10 each) gives roughly **380–420 turn rows**,
   against the 45 that exist today.
3. **Carry the spec fields** the oracle needs: `scenario_id`, `coverage_id`,
   `event_type`, `preconditions`, `slots_to_fill`, `expected_extract`,
   `expected_render`, `negative_constraints`, `eval_split`.
4. **Split policy from the catalog, not invented:** all Group J (safety) rows
   → eval only; bookings (D6/E6/F4/G3), corrections (I) → held-out eval.
5. **Add the third role** from the Training Prompt Format doc. Its use-case
   record (`primary_intent` × `travel_category` × `travel.use_case.*`, 46
   label names) is a *different* contract from extract/render — a
   classification/analytics record. It becomes role `usecase` with its own
   output schema, not a modification of the extract role.
6. **Wire the acceptance gates** from PO playbook §4 into `dataset_build`:
   scenario coverage, eval coverage, safety coverage, replay coverage,
   JSON/widget/vocab validity, drift check.

**Where Phase 2 stops.** Steps 1–6 produce a corpus whose *extract* side is
fully determined. The **render** side is not: the catalog says "sorted
cheapest", "rank less-touristy higher", "which is better value" without
defining any of them. The oracle cannot derive a label it has no rule for, so
generating those labels means inventing product policy and baking it into
thousands of examples. Phase 2 therefore generates render labels only for the
turns whose widget content is fully determined by the tool response, and stops
at the ranking boundary with the decision list below.

---

## 5. ⛔ The product decisions that gate the ranking layer

From `PRODUCT_INPUTS_REQUIRED` §1, plus two the hotel card forces. These are
the exact answers needed; each is a decision, not a discovery.

**Ranking / "what does best mean"**

1. **Default flight sort** for `show_flights` — e.g. `total_amount` ascending,
   tie-break `total_duration`? State the field and the tie-break.
2. **Default hotel sort** for `show_hotels` — price, rating, or a value score?
   If a value score, give the formula.
3. **Default activity sort** for `show_activities`.
4. **Default transfer sort** for `show_transfers`.
5. **"value" / "best" per intent** — an explicit formula. D4 says "cheapest",
   E3 asks "which is better value", H5 asks "which is better for us"; today
   these three would resolve three different ways.
6. **How preference tags re-weight** results (quiet, food, nonstop, family,
   pet-friendly) — weights or rules. Groups A2/C4/C6/I5 write these tags; no
   rule says what they do to an ordering.
7. **Exclusions (C6): filter or down-rank?** "mountains not beach" — does a
   beach result disappear or sink?
8. **Max results per list widget** (the doc suggests 3).

**Forced by the hotel card (1b)**

9. **`ratingLabel` thresholds** — the sample maps `8.7` → `"Excellent"`. Give
   the full band table (e.g. ≥9 Exceptional, ≥8 Excellent, ≥7 Very good, …).
10. **`category` buckets** — the sample shows `"Premium"`. Is this derived
    from star rating, price percentile, or a contracted-inventory tier?

**Provider precedence** (needed when two providers can serve one request)

11. Who wins; fallback order on empty/error; cross-provider de-duplication;
    whether contracted inventory gets a boost.

Until 1–8 are answered the promotion gate has nothing stable to score the
render role against; until 9–11 are answered the hotel card's `ratingLabel`
and `category` fields cannot be filled without guessing.

**Not blocking Phase 1a/1b otherwise:** the card can ship with `ratingLabel`
and `category` computed by a clearly-labelled placeholder rule, provided the
rule lives in one function with the decision cited — so replacing it later is
a one-line change rather than an archaeology exercise.

---

## 6. Sequencing

| Step | Blocked on | Output |
| :-- | :-- | :-- |
| 1a `flight-planner` | — | registered + a real execution advances |
| 1b hotel cards | — (placeholder for 9/10) | sandbox search returns card-shaped hotels |
| 2.1 vocab reconcile | — | drift check passes |
| 2.2–2.4 seed corpus | 2.1 | ~400 rows, gates green |
| 2.5 `usecase` role | 2.1 | third contract + schema |
| render/ranking labels | **decisions 1–8** | — |

## 7. Discipline

- Kind validation before prod, per `agents/rules/deployment-validation.md`.
- Credentials by reference only; no secret value is printed or committed.
- EHDB serve config untouched.
- `repos/travel/playbooks/itinerary-planner.yaml` and catalog
  `muno/playbooks/itinerary-planner` belong to session `local_46d9207c`.

---

## 8. Results — Phases 1 and 2 (2026-08-14)

### Phase 1a — `flight-planner`: registered + validated

`muno/playbooks/flight-planner` v2 on prod, v6 on kind.
`muno/playbooks/itinerary-planner` v67 untouched.

v41 could not execute as written. Three runtime-contract changes and one
graph defect had to be fixed, each found by **running** it, not reading it —
registration accepts a playbook the runtime then refuses:

| # | Symptom | Cause | Fix |
| :-- | :-- | :-- | :-- |
| 1 | `400 … untagged enum ToolDefinition` | `kind: agent` + `entrypoint:` is no longer a ToolKind ([#252](https://github.com/noetl/ai-meta/issues/252)) | 8 steps → `kind: playbook` + `path:`; `return_result`/`result_step`/`timeout` on the 4 whose result is consumed ([#136](https://github.com/noetl/ai-meta/issues/136)) |
| 2 | `422 Workflow must have a step named 'start'` | runtime requires it | added a `noop` `start` |
| 3 | all 4 routing arcs SKIPPED, turn wedged, re-drove `normalize_input` | step results are addressed **flat**; v41's `.context.` resolved to nothing so every `when` was false | stripped `.context` from 19 accessors |
| 4 | `render_widget_chat` never entered after `normalize_tool_response` | exclusive-arc targets are skipped **terminally**, and it was both an arc target and the convergence point | added the `skip_tool_dispatch` noop the live planner uses for the same reason |

Prod execution `346724338747056128` reaches `playbook.completed COMPLETED`
through the full path: `start → normalize_input → load_slot_state →
extract_turn → persist → append → call_google_places → normalize_tool_response
→ render_widget_chat → append_render_events → final_result`. Google Places
returned real data (`ok: true`, `isError: false`). `persist_render_docs` is
skipped by design (`when: post_docs | length > 0`).

Amadeus branch deleted (17 references). Two unreachable render-side remnants
kept and **labelled** rather than left silent.

### Phase 1b — `hotel-cards`: registered + validated against the sandbox

`muno/playbooks/hotel-cards` v3 on prod. Real HotelBeds **TEST** data:

```
count: 4   hotelbeds_env: test   currency: EUR   provider_error: none
  "Monterey Plaza Hotel & Spa"  stars 4  €675/night  €2700.84 total  4 nights
  real GIATA photo URL, real rateKey
```

Two defects found by reading the result rather than the status:

- First prod run returned `count: 0` with `provider_error: true` —
  `could not resolve a geolocation`. The provider's city fallback table holds
  **six** cities and "Monterey, California" is not one. Now coordinate-driven.
- `rooms[].price` carried the **stay total** while sitting next to a per-night
  `pricePerNight`, overstating it 4×. Now per-night, with `totalPrice` beside it.

**Ranking placeholder location:** one function, `_product_placeholder(rating,
stars, min_rate)` in the `map_cards` step, and nothing else. It computes only
`ratingLabel` and `category`. Every result carries
`"placeholder_fields": ["ratingLabel","category"]` so a consumer can tell
machine-readably which fields are not product-decided. Answering §5 items 9–10
is a single-function edit.

### Phase 2 — vocab reconciled, corpus staged, oracle gap quantified

- **F3 closed.** `oracle.py` and `slm.config.yaml` now agree exactly: **7
  tools, 16 render intents**. The 45 existing seed rows still run with zero
  vocab violations.
- **Corpus staged.** `scenarios/build_seed_from_catalog.py` expands all **82
  scenarios → 271 turn rows** (235 live, 36 roadmap) in the existing per-turn
  schema. Every group A–K covered; all Group J rows eval-only.
- **Divergence report** (`scenarios/check_oracle.py`) — the PO playbook §5
  "divergence → spec update" step:

```
rows with a declared render_intent: 230
  agree     :  89 (38.7%)
  disagree  : 141 (61.3%)
declared render intents the oracle CANNOT emit (8/16):
  order_detail, hotel_confirmation, show_activities, show_transfers,
  summary, trip_map, clarify, error
declared tools the oracle CANNOT request (3/7):
  hotelbeds.book_hotel, hotelbeds-activities.*, hotelbeds-transfers.*
cells fully agreeing (20): A1-A6, C1-C6, D1-D6, I6, K2
```

**Reconciling the vocabulary was necessary but not sufficient.** The agreeing
cells are exactly discovery + slot-collection + flights; everything hotels,
activities, transfers, itinerary, safety and most CTAs diverges. Two structural
causes, both in `oracle.py`, both determinate to fix:

1. **A linear flight-first funnel.** `show_hotels` is gated behind
   `picked_flight_offer_id`, so E/F/G scenarios resolve to `show_flights`. The
   catalog and live v67 treat every provider as a direct first-turn intent.
2. **`collect_missing` precedes place resolution.** `if not _ready(...)` is
   tested before the region branch, so B-group "trip to Paris" asks for dates
   instead of resolving the place.

Plus no refusal path at all — `clarify` and `error` are unreachable, so all of
Group J has zero derivable labels.

**This is the honest stopping line for the determinate work.** Generating
render labels now would bake a flight-funnel model the planner does not have
into thousands of examples. The next concrete step is reshaping the oracle's
decision chain to v67's routing — separate from, and prior to, the ranking
decisions in §5.

### Also found

- **[#268](https://github.com/noetl/ai-meta/issues/268) — the live Muno
  planner is running heuristic extraction in prod, silently.** Both LLM
  keychain aliases 403 (`secretmanager.versions.access` denied) on **both**
  candidate projects, so the alias is left undefined and extraction falls back
  (`llm_contract.fallback_used: true`) while the execution reports COMPLETED.
  Observed on live `itinerary-planner` executions at 17:22Z and 17:24Z,
  ~an hour before any work here ran. Needs an IAM grant (human carve-out).
  This also **supersedes** the #234 note that the LLM secrets were granted
  cross-project — true on 2026-08-05, not true now.
- **A pattern-based scan reported PASS while dropping 18 of 82 scenarios.**
  The `.docx` conversion left Unicode private-use glyphs (U+EC02) in front of
  18 headings; the parser's regex silently skipped them and every acceptance
  gate still read green. Fixed by stripping U+E000–U+F8FF.
- **The parallel session's Duffel repoint is no longer in its working tree and
  is not in `repos/travel` HEAD** — that edit appears to have been discarded
  rather than committed. Flagged, not acted on: that file is theirs.
