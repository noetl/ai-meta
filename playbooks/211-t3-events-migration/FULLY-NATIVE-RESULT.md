# Fully native on EHDB — no workarounds

2026-08-01. The three residuals from the EHDB-only cutover
([`EHDB-ONLY-RESULT.md`](EHDB-ONLY-RESULT.md)) are closed. The platform runs on
EHDB with **no NATS-named environment variables and no configuration
workarounds**.

## Final state

server **v3.60.1** · worker **v5.91.1** · gateway **v3.7.0** ·
ehdb `ddb7ac9`.

The writer now hosts six faces: commands (9100 ingest / 9101 claim /
9102 metrics) and events (9103 ingest / 9104 group-claim / 9105 SSE /
9106 metrics / 9107 KV / 9108 WAL fan-out).

## Evidence

| Check | Result |
| :-- | --: |
| Executions | **50/50 COMPLETED** |
| Durable log materialized | **950** |
| `noetl_materializer` cursor | 2048 → **2998**, lag 0 |
| `noetl_result_materializer` cursor | 2048 → **2998**, lag 0 |
| `noetl_state_materializer` cursor | 2048 → **2998**, lag 0 |
| `ehdb_events_cursor_errors` | **0** (was 26) |
| `WAL chain incomplete` occurrences | **0** |
| State-builder rehydration | `indexed_executions=121, wal_events=2048` |
| SSE frames to a live subscriber | **3093** |
| Worker ERROR lines | **0** |
| NATS-named env vars, cluster-wide | **0** |

All three group cursors advancing is the load-bearing line. Previously the
state-materializer cursor sat flat while everything else looked healthy — the
count of completed executions would have signed this off either way, which is
why the gate pairs cursors with the projection count.

## #217 — the off-server state builder, natively on EHDB

The WAL drain reads the writer's **raw fan-out face** (9108) via
`FeedSubscription`, replaying from cursor 0 on every boot with **no acks**.

That is a *subscription, not a consumer group*, and the choice is load-bearing:
a group persists a cursor, and a persisted cursor that outruns a freshly
restarted worker's **empty** in-memory index is exactly the
[#119](https://github.com/noetl/ai-meta/issues/119) stall. Replaying from 0
makes the index self-rehydrating by construction — proved by the rehydration
line above.

`NOETL_STATE_BUILDER=server` is gone; the server is back on `offserver`.

Both drains now share `apply_indexed` / `maybe_sweep` / `finish_batch` so the
transports cannot drift.

### A second defect found on the way

The state materializer called `ensure_consumer()` unconditionally — a NATS
connect to create a JetStream durable. With NATS deleted it failed, the `?`
propagated, and the loop exited with `state materializer NATS connect`. **The
materializer never started, silently**, while its group sat at a flat cursor.
Same shape as every other defect this migration produced: a component that dies
at startup and leaves the system looking healthy. Gated on the source.

### And a latent one the tests surfaced

`TERMINAL_EVENT_TYPES` in the WAL index listed only the **underscore**
spellings, but the orchestrator emits the **dotted** `playbook.completed`. A
normally-completing execution was never flagged terminal, so the drain's cheap
per-batch `evict` never fired on the common case and chains sat resident until
the TTL/byte sweep reclaimed them ([#166](https://github.com/noetl/ai-meta/issues/166)).
Not a correctness bug, but it silently disabled the fast path. The server's own
`is_terminal_event_type` had matched both spellings all along.

## #218 — the misnamed routing variable

`NOETL_FEED_FILTER_SUBJECT` is now the primary name; `NATS_FILTER_SUBJECT` is
read as a fallback for one release. The manifests use the new name **only** —
verified by the routing logs (`pool=system` / `pool=shared`) and by the
cluster-wide sweep finding zero NATS-named vars.

An unresolvable pool is now a **hard error** instead of a silent default to
`shared`. A worker that refuses to start is strictly better than one that
silently joins the wrong pool: the former is a crashloop an operator sees in
seconds, the latter is a cluster that looks healthy while nothing progresses.
A blank value never shadows the fallback, because a manifest with the key
present but empty is exactly how this would recur.

## #216 — cursor persists: root-caused, fixed, and no longer silent

**Root cause.** `CursorStore::store` writes a **fixed** temp path and renames it
over the live file, so two concurrent calls on the same store raced: both
created the temp file, the first `rename` moved it away, the second failed
`ENOENT`. The monotonic guard does not prevent this — two acks carrying
different committed values both pass `fetch_max`, then run concurrently. And
`GroupCoordinator::ack` releases the group lock *before* persisting, so the two
system-pool replicas' acks overlapped freely.

Fixed with a write lock held across temp-create → rename. The critical section
was already `fsync`-bound, so serialising costs nothing real.

**The test is verified meaningful**: removing the lock makes it fail with 80
errors, every one `No such file or directory (os error 2)` — the exact
signature seen on prod.

**No longer silent.** `ehdb-feed` still carries no logging dependency, so
`GroupCoordinator` keeps the last failure as `(group, message)` and the worker
logs it when the count moves — the counter carries the rate, the log carries the
reason. The message states the consequence explicitly (progress not durable → a
restart replays from an older cursor → records re-delivered, never lost),
because "cursor persist failed" on its own reads far more alarming than it is.

Prod now reports **0** cursor errors across a full run and a restart, and the
groups resume `origin=persisted` rather than `fallback_tail`.

## The gateway OIDC test

`oidc_bad_signature_rejected` was red on `main`. It was a **test bug, not a
security hole** — the token was rejected either way, just under `oidc_invalid`
instead of `oidc_bad_signature`.

An RS256 signature is 256 bytes → 342 base64url chars, and the final char
encodes only the trailing 2 bits, so most substitutions there produce a string
that fails to *decode*. The test flipped the last char, exercising the decode
path while asserting the verify path. Tampering a middle char keeps the segment
valid base64url so it decodes cleanly and genuinely fails verification. A
companion test pins that the undecodable case is **still rejected**, so the
reason code cannot be "fixed" back and a regression that started *accepting* it
would fail. Landed in noetl/gateway#36.

## What shipped

| Repo | PR | What |
| :-- | :-- | :-- |
| noetl/ehdb | [#308](https://github.com/noetl/ehdb/pull/308) | `FeedSubscription` by DNS name |
| noetl/ehdb | [#309](https://github.com/noetl/ehdb/pull/309) | cursor write lock + last-error surfacing |
| noetl/ehdb | [#310](https://github.com/noetl/ehdb/pull/310) | drop the unused import |
| noetl/worker | [#204](https://github.com/noetl/worker/pull/204) | state-builder WAL drain on EHDB |
| noetl/worker | [#205](https://github.com/noetl/worker/pull/205) | `NOETL_FEED_FILTER_SUBJECT` |
| noetl/worker | [#206](https://github.com/noetl/worker/pull/206) | log cursor-persist failures |
| noetl/worker | [#207](https://github.com/noetl/worker/pull/207) | skip `ensure_consumer` on EHDB |
| noetl/gateway | [#36](https://github.com/noetl/gateway/pull/36) | OIDC tamper fix |

## Remaining NATS-shaped code

Two different things, and conflating them caused a wrong call in the first
draft of this document.

**The `nats` tool kind is NOT dead — it is a user-facing feature.** A playbook
step with `kind: nats` connects to the **user's own** broker, named by the
step's `url` or a keychain credential alias. It sits beside `postgres`,
`duckdb`, `http` and the object-store kinds: users bring their own external
services for business logic. It never touched the internal bus, so "no workload
carries a NATS URL" says nothing about it — the URL comes from the playbook.
The tool lives in the separate `noetl-tools` crate with its own `async-nats`.
Verified working on the post-removal build; see
[noetl/ai-meta#219](https://github.com/noetl/ai-meta/issues/219).

**The internal drain/source paths are dead** — those are the migration's
leftovers and are a genuine cleanup. But note `state_builder`'s WAL-rehydrate
path still reads `NATS_URL` and is live under `shard_read_verify`, so the
`async-nats` dependency itself cannot be dropped from the worker either.
