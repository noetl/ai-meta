# Session summary — prod restore + adiona flights/hotels validation, 2026-09-15

Single session, ~8 h. Start state: adiona/frontend#21 and #22 merged
(ops#308 / travel#121 / frontend#23) but unregistered; prod had executed nothing
for ~36 h. End state: prod executing, flights validated on live Duffel, one
platform gap open for an owner decision.

Read `README.md` → `RECOVERY-2026-09-15.md` → `CATALOG-SPLIT-ROOTCAUSE.md` →
`EXTERNALISED-RESULT-DEREF.md` → `PLANNER-DEPLOY-ABORTED.md` in that order.

## 1. Prod execution restored

`noetl-cmdbus-writer-0` was wedged: silent 2026-09-13T16:56 → 2026-09-15T06:41
(~38 h), no heartbeats, while the server hot-looped re-orchestrating two stranded
executions (298 publishes / 20 min). Cancel was impossible — the API reported
both as "not found" while actively publishing for them.

Pod delete → StatefulSet recreate (PVCs `Retain`). Back 1/1 in ~20 s. Hot loop
gone, executions flowed again.

**Data verified byte-identical across the restart:**

```
eventlog.jsonl  215120526 / 19141   (unchanged)
catalog.jsonl     1365692 / 20      (unchanged)
projection.jsonl  2479294 / 641     (unchanged)
cmdbus_files    16204 -> 16217      (normal growth)
eventbus_parts   1093 -> 1094       (normal growth)
```

`/data/cmdbus`, `/data/eventbus`, `/data/eventkv` are separate ext4 PVCs.

## 2. Catalog split — fixed

`/api/catalog/list` alternated between two datasets (2533 entries with
normalized kinds vs 1370 with legacy `Playbook`/`mcp` kinds). Root cause:
`NOETL_CATALOG_READ_SOURCE=verify` serving from a relation whose fold was
incomplete — `coverage: fold_missing=5, full_coverage=false`, the exact
"partial coverage is a WRONG read" case `playbooks/catalog-read-cutover`
predicts: `get_latest` answers "not found" for a path that exists.

Applied the playbook's own documented rollback:

```bash
kubectl -n noetl set env sts/noetl-server-rust-embedded \
  -c noetl-server NOETL_CATALOG_READ_SOURCE=postgres     # revert: =verify
```

⚠ The playbook targets `deploy/noetl-server-rust`, now **0/0 and vestigial**.
Prod runs `sts/noetl-server-rust-embedded`. The playbook needs that correction.

Result: 10/10 consistent reads; registration then resolved correctly.

## 3. Registered to prod

duffel **v20**, hotelbeds **v9**, hotel-cards **v8**, flights-details **v3**
(later versions supersede the first pass, which was written before the catalog
fix). All additive — the catalog is append-only, nothing was overwritten.

Fixed on the way: prod's registered Duffel provider had been pointing at the
**retired** GCP project `noetl-demo-19700101` (fix `a5d6360` existed in git but
was never registered), so the shared provider could not read its secret.

## 4. Flights — VALIDATED on live Duffel

| run | execution id | result |
|---|---|---|
| one-way | `358155140093452288` | 19.0 s, 4 offers |
| one-way enriched | `358157105166819328` | 19.8 s, 4 offers, `enrich_ok=4` |
| round-trip **split** | `358157620630003712` | 20.4 s, 7 offers — outbound 4 / inbound 3 |
| round-trip combined | `358157105946959872` | 19.6 s, 3 offers |
| one-way LAX | `358157621414338560` | 0 offers (test key has no LAX inventory) |

Confirmed populated on real data: `logo_symbol_url` / `logo_lockup_url` on every
offer, `city`, `airport_name`, `terminal`, `carrier_name`, `direction`,
`price{base,tax}`, exact `criteria` echo, and real multi-segment connections
(`JFK→MSP→MCO`, `stops=1`, legs emitted separately). Direction tagging verified
semantically: outbound offers fly JFK→MCO, inbound fly MCO→JFK.

**Two assumptions overturned:**
- Duffel's **search** response already carries baggage AND conditions with
  `enrich_offers` OFF (`baggage_known` / `conditions_known` true on every live
  offer). The planner's note that only the single-offer GET supplies these did
  not hold. Do not assume per-offer enrichment is needed for baggage.
- The **50-offer cap is UNTESTED** — the test key returned 4–7 offers per search,
  so the cap was never the limiter.

## 5. Hotels — provider validated, end-to-end BLOCKED

Real HotelBeds payload (214,805 bytes, exec `358159477016371200`): **5 hotels,
509 images, 67 rates**, room-attributed photos on all 5. Against the old
behaviour that is 17× the images (cap was 6/hotel) and 13× the rates (1/hotel).
`max_hotels: 20` threaded correctly; the test key only has 5 Monterey hotels.

**But the card output is empty**, because a child result over the runtime byte
budget arrives as a `_ref` and hydration is read-side only — see
`EXTERNALISED-RESULT-DEREF.md`. This is very likely the "hotel search stopped
working" report in adiona/frontend#22, and adiona/frontend#22's own payload
growth is what pushes hotels over the floor.

Interim: noetl/travel#122 makes it **fail loud** (`deref_error` naming cause and
byte size) instead of silently returning nothing — or, worse, returning the
`_truncated` sample as if it were the whole answer.

## 6. Planner deploy — aborted

Prod is **ahead of** main, not behind. See `PLANNER-DEPLOY-ABORTED.md`.

## Errors made in this session, recorded

Four confident-but-wrong readings, all corrected before acting on them except
where noted:

1. "The EHDB tier workload is missing" — it is `noetl-cmdbus-writer`;
   `grep -i ehdb` does not match it. Acting on it would have meant a second
   writer on one PVC.
2. "Nothing is listening on 9110" — it is a framed protocol; an HTTP probe is
   read as a bad frame header.
3. "`/api/executions/{id}/cancel` → 405 proves the execution exists" — 405 is
   "GET not allowed on this route", for any id.
4. "Prod planner is 17 commits behind main" — read from the pre-flip stale
   catalog store.

Plus one caught only by a later check: the first deref cut returned the
`_truncated` sample and reported 1 hotel as the whole answer.

The recurring shape: **a confident read of the wrong store, or of a probe that
does not mean what it appears to.** This loop's doc already warns that false
zeros are the failure mode here; this session produced four more.
