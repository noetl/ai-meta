# Externalised-result hydration — the fix, and what the four earlier attempts missed

**Status: SHIPPED AND VERIFIED IN PRODUCTION, 2026-09-16.** noetl/server#437 (v3.109.3) +
noetl/worker#320 (v5.132.5) + noetl/travel#123 (hotel-cards v10). adiona/frontend#22 closed.
**Supersedes** the fix sections of `HYDRATION-FIX.md`, `HYDRATION-STATE-OF-PLAY.md` and
`HYDRATION-FINAL-LOCALIZATION.md` (their *forensics* still stand; their proposed fixes were
one layer short — see §4).

---

## 1. The defect, stated once

`noetl.result_store` is written only while `NOETL_RESULT_STORE_DUAL_WRITE` is on.
Prod, measured 2026-09-15 with `kubectl get deploy -n noetl -o json`:

```
deploy/noetl-server-rust                  MINT_AUTHORITATIVE=true   DUAL_WRITE=false   STATE_BUILDER=offserver   PERMANENT_LOG_LEAN=true
deploy/noetl-worker-rust                  MINT_AUTHORITATIVE=UNSET  URI_RESOLVE=true   PRODUCER_STAGE=true
deploy/noetl-worker-system-pool           MINT_AUTHORITATIVE=true   PRODUCER_STAGE=true
deploy/noetl-worker-system-pool-shard1    MINT_AUTHORITATIVE=true   PRODUCER_STAGE=true
```

`noetl-worker-rust` is the odd one out. Without `MINT_AUTHORITATIVE` it took the
non-authoritative branch in `build_call_done_result` and emitted the **legacy**
`noetl://execution/<eid>/result/<step>/<id>` ref. The server, which *is*
mint-authoritative, had stopped writing the rows that resolve it.

Every read of such a ref answered not-found. Measured: **HTTP 404 in 0.19 s**, while
**214,805 bytes** of the result sat in `noetl.object_store` under the canonical key.

Nothing reports that as an error. The worker maps 404 to `Ok(None)` and leaves the step
bound to its summary; the status view leaves the event "as stored". So
`muno/playbooks/hotel-cards` returned **0 hotels with `status: success`**, for two days.

**The config split is the cause; the missing `_uri` and the missing tier fallback are the
two places that split was able to do damage.** Both are now closed, and neither can be
reopened by an env var.

## 2. The two fixes

**FIX 2 — worker (noetl/worker#320).** `build_call_done_result` emits the canonical `_uri`
alongside `_ref`, **unconditionally**. The consume side reads `_uri` and hands it to
`resolve_by_urn`, which reads the tier directly; nothing had ever populated it, so that
fast path could not be taken. Emitting it unconditionally is the point — gating it on
`mint_authoritative()` would reproduce the very per-pool split that caused the outage.

Also: a `reference` object carrying `ref` but no `uri` no longer short-circuits the locator
search. `reference.uri` is stamped by `stamp_logical_uri`, which the executor runs *after*
`build_call_done_result` returns, so an emit path that skips the stamp would otherwise
throw away the `_uri` one level below.

**FIX 3 — server (noetl/server#437).** `ResultStoreService::resolve` reads
`noetl.result_store` first and, on a miss, the #104 object tier, keyed on
`(execution_id, name)` — the only coordinates a legacy ref carries.

## 3. The mistake inside FIX 3, and why it matters more than the fix

The first cut wired the fallback into `handlers::result_store::resolve_ref`. In kind it
logged `legacy store miss served from the #104 tier` **four times** — and the parent step
still received **0 items**.

`noetl.result_store` has **six** read sites. The HTTP endpoint is one, and it is not the one
that feeds a parent step. An over-budget `kind: playbook` child reaches its parent through:

* `services::execution::hydrate_status_result` — what `GET /api/executions/{id}` serves,
  what the `playbook` tool polls for `return_result: true`, and what `hotel-cards`'
  `_materialise()` calls; and
* `handlers::events::hydrate_result_references` — what turns a stripped event back into a
  rendered input.

Both call the service **directly**. A fallback in the handler is invisible to them.

So the fallback lives in the service, and the CI guard asserts the inverse of the obvious
property. Not "the handler calls the fallback" — that is exactly what would have passed on
the broken version — but **`every_result_store_read_site_goes_through_the_fallback`**.

## 4. Why #315, #317 and #319 each shipped and changed nothing

| | fixed | why it did not help |
|---|---|---|
| #315 | `contains_summary_bulk` / `is_reference_stub` | the predicate was never reached |
| #317 | `reference_locators` for three fixed paths | the real locator is one level deeper |
| #319 | `reference_locators`, recursive | the gate opened, but the resolve it enabled hits a 404 |
| #343 | the 404 itself, both sides | — |

Each was correct. Each was validated against a shape, or a layer, one step short of the real
one. The common failure is that **every test started below the thing that was broken.**

## 5. Proof — kind, configured exactly as prod

`MINT_AUTHORITATIVE=true`, `DUAL_WRITE=false`, `PERMANENT_LOG_LEAN=true`,
`STATE_BUILDER=offserver` on the server; `URI_RESOLVE=true`, `PRODUCER_STAGE=true`,
`MINT_AUTHORITATIVE` unset on the worker.

Same legacy ref, both server images:

| | pre-fix `3.108.0` | FIX 3 |
|---|---|---|
| `GET /api/result/resolve?ref=…` | **404** `result not found`, 5.6 ms | **200**, 172,577 bytes, 16 ms |

Same child execution, the `_materialise()` read path `GET /api/executions/{child}`:

| worker | server | items | rooms | images | bare refs |
|---|---|---|---|---|---|
| pre-fix | pre-fix | **1** | 1 | 1 | 1 |
| pre-fix | FIX 3 | **20** | 10 | 8 | 0 |
| FIX 2 | FIX 3 | **20** | 10 | 8 | 0 |
| FIX 2 | pre-fix | **1** | 1 | 1 | 1 |

Non-regression: a payload small enough to stay inline delivers **3 of 3** items straight to
the consuming step with **zero locator keys leaked** — the inline path is untouched.

**The last row sets the rollout order.** The worker fix alone does not restore hotels, so
the server ships first. It is safe against unpatched workers: it only adds a fallback on a
path that currently answers 404.

## 5b. The mistake that nearly shipped: the tier is GCS on prod, Postgres in kind

The first two commits of FIX 3 read the tier with **SQL against
`noetl.object_store`**. That would have found **nothing on production**.

```
NOETL_OBJECT_STORE_BACKEND=gcs
NOETL_OBJECT_STORE_GCS_BUCKET=shastaratech-noetl-prod-results
noetl_object_store_ops_total{backend="gcs",op="put"} 606
noetl_object_store_ops_total{backend="gcs",op="get"} 142
```

kind runs the Postgres backend. So a fix that "passed in kind" would have been
deployed to prod and changed nothing — **the fourth iteration of the same
failure this whole issue is about: validated one layer short of the real one.**

It was caught by asking one question that had not been asked: *where do the
bytes actually live in production?* The answer was two `kubectl`/`gcloud`
commands away and should have been step one.

Resolution now goes through `ObjectBackend::list` + `get`, which serves both
backends. That needs the §7 key **prefix** rather than a suffix match, so the
placement is derived — env/region/cell and shard space from `NOETL_RESULT_CELL*`,
the shard as `shard_key(tenant, project, execution_id) % shard_count` (which does
**not** depend on step/frame/row/attempt — that is what makes a step-level prefix
possible at all), and the date from the execution-id snowflake rather than the
wall clock.

A wrong derivation would make the fallback silently never fire — indistinguishable
from the bug — so it is pinned against **nine real object keys**, five read out of
the production GCS bucket and four from kind:

```
prod eid=358337687603650560 hotelbeds_dispatch shard=s0004 date=2026-09-15  OK
prod eid=358387240549752832 hotelbeds_dispatch shard=s0004 date=2026-09-15  OK
prod eid=351442299651104768 firestore_dispatch shard=s0004 date=2026-08-27  OK
prod eid=358157628485935104 duffel_dispatch    shard=s0007 date=2026-09-15  OK
prod eid=351442533462581248 firestore_dispatch shard=s0007 date=2026-08-27  OK
kind eid=358488951972958208 emit               shard=s0184 date=2026-09-16  OK
kind eid=358494482770956288 emit               shard=s0066 date=2026-09-16  OK
kind eid=358494179833155584 fetch              shard=s0207 date=2026-09-16  OK
kind eid=358494181552820224 emit               shard=s0090 date=2026-09-16  OK
```

Re-verified in kind afterwards: the derived prefix matches the live object
exactly, so the prefix walk — not the Postgres suffix fallback — is the serving
path. Verdict HYDRATED: 20 items, 10 rooms, 8 images, 0 bare refs.

**Known limitation, not widened here:** the pre-existing `resolve_canonical`
path has the same Postgres-only assumption and is therefore also blind on a GCS
backend. Worth its own issue.

## 6. Gates (all verified red without the fix)

* `noetl/worker` `parent_consuming_an_externalised_child_receives_the_hydrated_payload` —
  the first test in this repo to join the producer and the consumer. A real
  `build_call_done_result` against a mock control plane whose legacy resolve answers
  **404, always** (the measured prod response), consumed by a real
  `resolve_context_references`. Reverting FIX 2 reproduces the production symptom in-process:
  `the consuming step was handed no hotel array at all`.
* `noetl/worker` `the_producer_always_emits_the_canonical_uri_beside_the_ref` — source-level,
  including an assertion that the emit is **not** conditional on `mint_authoritative`.
* `noetl/worker` `an_unstamped_reference_object_does_not_hide_the_accessor_uri`.
* `noetl/server` `every_result_store_read_site_goes_through_the_fallback`, plus ordering
  (store before tier), error degradation (never 404→500), and handler→service→query
  reachability.
* `noetl/server` `tier_step_pattern` anchoring: `map` cannot match `map_offers`, a step named
  `%` cannot match every result. Serving the **wrong** result would be worse than the 404 it
  replaces, because it is silent.

## 7. Observability

`noetl_result_store_tier_fallback_total{outcome=served|miss|error}`, recorded at the service
so it counts regardless of caller. `served` climbing measures how much result delivery
currently depends on the fallback; **`served` falling to zero is the signal that every
producer emits `_uri` and the legacy mint can be retired.**

## 8. Not this bug

**noetl/worker#316** (cross-pod shm attach) is separate and was **ruled out by measurement**:
the failing fetch returns a clean, fast HTTP 404, not a hang. It remains open on its own merits.

## 9. Environment note

The kind cluster's event pipeline was stalled before any of this work, unrelated to #343:
stale events carrying `catalog_id=0` violated `event_catalog_id_fkey` and blocked every
insert queued behind them. Unblocked **additively** with one sentinel `noetl.catalog` row at
`catalog_id=0` (path `_sentinel/unattributed-events`), marked safe to delete. Nothing was
deleted. Remove it when kind no longer needs to drain that backlog.


---

# 10. Production rollout — 2026-09-16

| | |
|---|---|
| `noetl/server` | **v3.109.3** `sha256:af84aa1d…` → `sts/noetl-server-rust-embedded`, 07:16Z |
| `noetl/worker` | **v5.132.5** `sha256:14759cee…` → `deploy/noetl-worker-rust` + both system pools, 07:36Z |
| `noetl/travel` | **hotel-cards v10** registered to the prod catalog |

Rollback rows in `noetl/ops` `ci/manifests/noetl/ledger/` (noetl/ops#310) — the
row above each is the target.

**Order was measured, not assumed.** The kind matrix showed the worker fix alone
leaves the read path returning 1 item, because the path that feeds a parent step
is server-side. Server first, canary on the affected worker pool, then the
system pools.

## The proof, on the real stranded result

```
GET /api/result/resolve?ref=noetl://execution/358337687603650560/result/hotelbeds_dispatch/…
  before:  HTTP 404 "result not found"    28 bytes   0.228 s
  after:   HTTP 200                  214,811 bytes   1.42 s  (0.61 s warm)
```

Those bytes: **5 hotels, 509 images**, `status_code: 200`, `isError: false` —
the search that had been sitting in GCS the whole time, and the same object the
09-15 forensics measured at 214,805 bytes.

## Live runs after rollout

```
hotels   3 cards   13 rooms   243 images   deref_error: null   no failed steps
flights  50 offers  50/50 with airline logo, itineraries, baggage_options, conditions_options
```

## How much of the platform depended on the broken path

```
noetl_result_store_tier_fallback_total{outcome="served"} 45
noetl_result_store_tier_fallback_total{outcome="miss"}    1
```

Forty-five result reads served by the fallback in the first hour — each a silent
404 before today. **When that counter reaches zero, every producer is emitting
`_uri` and the legacy mint can be retired.** That is the retirement signal.

## 11. The bug underneath the bug

With hydration working, `map_cards` crashed on the first real hotel:

```
TypeError: unsupported operand type(s) for -: 'str' and 'str'    (_price_bands)
```

HotelBeds returns money as strings. The adiona/frontend#22 rooms/bands code had
**never once executed against live data** — `hotels` was always empty, so the
`for hotel in hotels` body never ran. Fixed in noetl/travel#123, verified against
the real payload in four shapes with the v9 code as a negative control.
`rooms` 0 → 13, `images` 0 → 243.

Worth keeping in view: **a bug that empties a collection hides every bug in the
code that consumes it.** Two days of "hotels return nothing" concealed a crash
that would have been obvious on the first working run. Expect more of these
whenever a long-empty path starts carrying data again.

## 12. Honest caveats

* **3 hotels, not ~20.** `raw_total` = `hotels_total` = card count = 3. The
  HotelBeds **test sandbox** returns a small fixed set (it answers a Barcelona
  query with Monterey hotels). The `limit` → `max_hotels` threading works;
  nothing downstream truncates. A larger number needs the production HotelBeds
  environment, which is a credentials decision, not a code one.
* **`resolve_canonical` is still Postgres-only** and therefore blind on a GCS
  backend — the same limitation the legacy fallback just shed. Not widened here;
  it deserves its own issue.
* **`deploy/noetl-server-rust` is 0/0 and vestigial** but still carries
  `NOETL_CATALOG_READ_SOURCE=verify`, while the workload actually serving has
  `postgres`. Reading it gives a confidently wrong answer about prod. Delete or
  annotate it.
* **The kind event pipeline was stalled before this work**, unrelated: stale
  events with `catalog_id=0` violating `event_catalog_id_fkey`. Unblocked
  additively with one sentinel catalog row, marked safe to delete. Nothing was
  deleted.
