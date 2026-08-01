# EHDB-only cutover — result

**NATS is deleted from `shastaratech-noetl-prod`. The platform runs on EHDB
alone and is end-to-end green.** 2026-08-01.

Authorized by the user on the basis that this cluster carries no real traffic,
so no dual-run, canary or parity soak was required — the discipline was
deploy → test → fix-forward until green.

## Final state

| Component | Version | Bus |
| :-- | :-- | :-- |
| `noetl-server-rust` | **v3.60.1** | `NOETL_COMMAND_BUS=ehdb`, `NOETL_EVENT_BUS=ehdb` |
| `noetl-cmdbus-writer-0` | **v5.88.0** | hosts commands (9100/9101/9102) + events (9103/9104/9105/9106) + **KV (9107)** |
| `noetl-worker-rust`, system pool ×2 | **v5.88.0** | commands + all materializers on EHDB |
| `gateway` | **v3.7.0** | SSE on the EHDB feed, session + request stores on **EHDB KV**, no NATS code path |

`GET /api/health` → `"nats":"not_configured"`. Namespaces `nats` and
`nats-supercluster` (6 pods) are **deleted**.

## End-to-end evidence (EHDB-only, NATS absent)

| Check | Result |
| :-- | :-- |
| Playbook executions | **50/50 COMPLETED** in ~60 s |
| Events published to the EHDB bus | **950** (`noetl_ehdb_events_published_total`, 8 event types) |
| Durable log materialized | **950** (`noetl_events_projected_total`) — exact match |
| Events-feed group cursors | advanced 2048 → **2998** (950 records) |
| EHDB publish errors | **0** |
| SSE broadcast face | **2559 frames** delivered to a live subscriber |
| Gateway errors | **0** |
| Scheduled-cleanup CronJob | `Complete 1/1` |

## What broke on the way, and why (the fix-forward log)

Five real defects, each found by testing rather than reasoning:

1. **`set image '*'` replaced the init container.** The system pool's
   `wait-for-api` init container is `curlimages/curl`; the wildcard swapped it
   for the worker image, which has no `curl`, so the init loop spun forever.
   *Fix: target containers by name.*

2. **The result + state materializers were still on NATS.** Only the event
   materializer had been migrated, so once the server stopped publishing to
   NATS they drained a stream nobody writes — silently. *Fix: noetl/worker#203
   added a `MaterializerFeed` adapter rather than a third copy of the loop.*

3. **The off-server state builder fed its WAL from `noetl_events`.** A **fourth**
   consumer nobody had inventoried. With NATS gone the WAL chain was never
   built, every orchestrate returned `WAL chain incomplete; returning no-op`,
   and all executions stalled at RUNNING with **no error anywhere**. *Fix:
   `NOETL_STATE_BUILDER=server` — state construction moves back to the server,
   which reads `noetl.event` directly.*

4. **The gateway hard-failed on a missing NATS.** `start_nats_listener` was
   called with `?`, so removing `NATS_URL` made it exit 1 at boot. *Fix:
   noetl/gateway#35 removed the dead NATS callback listener entirely — see
   [#213](https://github.com/noetl/ai-meta/issues/213).*

5. **`should_publish` required a NATS connection.** The subtlest one. Removing
   `NOETL_NATS_URL` made the gate false for every event, so the chokepoint fell
   through to `insert_rows` and the server quietly resumed writing `noetl.event`
   synchronously. **Nothing errored** — executions completed, the durable log
   was written, and the EHDB events feed simply sat at a flat cursor while the
   entire CQRS publish path was inert. *Fix: noetl/server#295 gates on "does the
   configured bus have a usable transport", per mode.*

Defects 3 and 5 share a shape worth naming: **both failed silently and looked
healthy.** A green execution count would have signed off on a platform whose
event bus was doing nothing. That is why the acceptance evidence above pairs
`published` with `projected` and with the feed cursor, rather than trusting
"executions completed".

## Known residuals (not blockers)

- **`ehdb_events_cursor_errors = 26`.** Per-group cursor persists are failing
  intermittently. Correctness is unaffected — an unpersisted cursor causes
  replay, never loss, and `events/project` dedupes by `event_id` — but it means
  group progress is not durable across a writer restart. **Not diagnosable from
  logs**: `ehdb-feed` carries no logging dependency, so the counter is
  incremented without a message, and the host does not log it either. That is an
  observability gap I introduced. Tracked as noetl/ai-meta#216.
- **The state materializer no longer runs.** It is part of the off-server
  state-builder subsystem (#166 Phase 2, explicitly a SHADOW tier) that was
  disabled with `NOETL_STATE_BUILDER=server`. Expected, not a regression — but
  it means the off-server drive path is **off** on this cluster and would need
  the state-builder drain migrated to EHDB before it can be re-enabled. Tracked
  as noetl/ai-meta#217.
- **`NATS_FILTER_SUBJECT` is still set** on the workers. It is now a
  *misnamed* variable, not a NATS dependency: the EHDB subject filter is derived
  from it (`noetl.commands.system.>` → pool `system`). Removing it silently
  collapsed the system pool onto `commands.shared.>` so it stopped claiming
  orchestrate commands — another silent failure. Restoring it fixed it. The
  clean fix is a rename with a fallback; tracked as noetl/ai-meta#218.
- **`ingress::verify::tests::oidc_bad_signature_rejected` fails** on
  `noetl/gateway` `main`. Pre-existing, unrelated to this work, confirmed by
  running it on a clean `origin/main`. Security-adjacent, so worth fixing.

## Disaster recovery

NATS can be recreated from [`nats-dr/`](nats-dr/) — stream, consumer and KV
definitions plus the full k8s IaC. Definitions only, no message data, which is
correct: the events stream's contents were transient under a 24 h TTL and every
event is already in `noetl.event`, which is untouched. A restore must rotate the
plaintext `noetl:noetl` credential rather than reuse it.

## Retired with the teardown

[#188](https://github.com/noetl/ai-meta/issues/188) — the plaintext
`noetl:noetl` credential is gone from every workload's environment.
