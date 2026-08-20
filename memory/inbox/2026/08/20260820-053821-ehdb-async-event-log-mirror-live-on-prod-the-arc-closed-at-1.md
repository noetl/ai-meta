# EHDB async event-log mirror live on prod; the arc closed at ~13s
- Timestamp: 2026-08-20T04:10:00Z
- Author: Claude
- Tags: ehdb,latency,prod,mirror,155,238

## Summary

The event-log mirror ran **inline on the `emit_events` chokepoint**, costing a
measured 110 ms/call x 76 calls ~ 8.4 s per Muno planner turn even after the
runtime replay cache had cut it from 85.6 s. It now goes through a bounded
in-process queue drained by one task, with a backpressure ladder that has **no
drop rung**. Live on prod since 2026-08-19.

**Live versions/flags (verified 2026-08-20):** server **v3.83.1**, user-pool
worker **v5.120.0**, `cmdbus-writer` **v5.119.1** (deliberately held back — it
carries the durable log and the Option 1 runtime cache), system pools v5.118.2.
`NOETL_EHDB_EVENTLOG_MIRROR_ASYNC=true`,
`NOETL_EHDB_CROSSSTORE_PARITY_LAG_TOLERANCE_SECS=30`. Tiers: eventlog
`primary`, projection/kv/object `shadow`, **`NOETL_EHDB_VECTOR` not set at all**.

**Measured:** `emit_mirror` 78.6-87.6 ms -> **0.1 ms/call** (~6.0 s -> 0.007 s
per turn); median warm turn **16.9 s -> 13.0 s**; the whole arc ~89 s -> ~13 s.
Parity `match` 268 / `divergent` 0; conservation exact 380 = 380;
`queue_full_inline` 0; `served_primary` 925 with every demote outcome 0.

## Actions

- Rollback is ONE flag, no image roll: `MIRROR_ASYNC=false` **and** set the
  tolerance back to `0`. Set both or neither — async on with the window at 0
  makes the comparator judge a healthy tier on its own liveness.
- Size the window by **measuring**, never by choosing: turn async on behind a
  wide window, read `mirror_lag_seconds`, then set above the observed p99. Prod
  came back p99 699 ms / max < 1 s, hence 30 s. Keep it **below**
  `SETTLE_SECS` (120 s) so the background sampler still compares everything.
- Runbooks: `ehdb.wiki/Runbook-Async-Event-Log-Mirror` and
  `ops/runbooks/noetl-ehdb-mirror-async.md`.

## Lessons worth not relearning

- **A counter can read correctly while the events it counts are being lost.**
  The queue's first implementation used `tx.send(batch)`, which moves the batch
  into the future, so a timeout cancellation discarded it — 32 of 60 records
  never reached the relay while `queue_full_inline` incremented by exactly the
  right amount. `reserve()` keeps the batch in the caller's frame. The test that
  caught it asserts **arrival**, not counters.
- **A tolerance window must be a discrimination, not a suppression.** Two
  controls run on ONE fixture with only the horizon moved: forgiven inside the
  window, still `missing_event` outside it. A comparator taught to ignore
  everything passes a single "clean parity under tolerance" control perfectly.
- **Probing a counter can inflate it.** A `pending_mirror` verdict was still
  writing `crossstore_divergence_total`, the counter ops#257 pages on — so
  investigating an in-flight execution inflated the number its own alert reads.
  noetl/ai-meta#264 in a second place; fixed in server#354.
- **Two non-atomic reads look like divergence.** The authoritative page and the
  tier page are separate reads, so a still-emitting execution legitimately holds
  a tier record the authoritative page never saw. Bound it by the **full**
  page's max id — the comparable prefix is empty in exactly the case that needs
  the fix.
- **The stale artefact was our own memory index.** `MEMORY.md` asserted "zero
  alerting on prod" for two weeks after #238 was fixed and closed, and that
  claim was propagated into ops#262 and two #155 comments before anyone checked
  the live project. Prod actually had 5 GMP Rules, 8 alert policies, 2 channels.

## Repos
- `noetl/server` — v3.83.0 (#353 queue + window), v3.83.1 (#354 pending-verdict fix)
- `noetl/worker` — v5.120.0 (#282 tier-append path metric)
- `noetl/ops` — #262 alerts, #263 promtool tests, #264 policies-as-code, #265/#266 delivery + routing
- `noetl/ehdb` — #316 runtime cache, #317 batch append substrate

## Related
- noetl/ai-meta#155 — the arc (still open: FIX E, and the residuals below)
- noetl/ai-meta#238 — alerting; **premise was wrong**, two paths and only one delivers
- noetl/ai-meta#283 — the `noetl.command (event_id)` index, blocked on a superuser GRANT
- noetl/ai-meta#284 — Option 2 batch flag still OFF on prod (`batch=0` both replicas)
- noetl/ai-meta#285 — the 8s stall fix, opened retroactively and closed
- noetl/ai-meta#264 — partially fixed; the endpoint still records on the divergent path
