# Externalised-result hydration — the fix, and what the four earlier attempts missed

**Status:** fixes implemented, gated, proven in kind. noetl/server#437 + noetl/worker#320.
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
