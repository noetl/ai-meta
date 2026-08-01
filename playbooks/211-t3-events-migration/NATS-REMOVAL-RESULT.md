# NATS dead-code removal — result

2026-08-01. The unreachable NATS code is gone from server, gateway and the
worker's command path. The platform is still end-to-end green on EHDB.

server **v3.60.2** · worker **v5.91.2** · gateway **v3.7.1**.
`GET /api/health` → `"nats":"removed"`.

## Evidence (after the removal)

| Check | Result |
| :-- | --: |
| Executions | **50/50 COMPLETED** |
| Durable log materialized | **950** |
| `noetl_materializer` cursor | 3072 → **4022**, lag 0 |
| `noetl_result_materializer` cursor | 3072 → **4022**, lag 0 |
| `noetl_state_materializer` cursor | 3072 → **4022**, lag 0 |
| `ehdb_events_cursor_errors` | **0** |
| `WAL chain incomplete` | **0** |
| SSE frames to a live subscriber | **4022** |
| Worker ERROR lines | **0** |
| Pool routing | `pool=system` / `pool=shared` |

## What the survey saved

Four things were NATS-*named* and would have gone with a grep-driven pass.
Every one is on the live EHDB path:

| Kept as | Was | Why it is live |
| :-- | :-- | :-- |
| `worker/src/dispatch.rs` | `worker/src/nats/{source,subscriber}.rs` | `CommandNotification` (the EHDB claim path decodes into it), `segment_from_filter` (derives the **EHDB pool**), `claim_outcome` + `translate` + `deserialize_command_id` (always shared by both sources — its own doc said so) |
| `gateway` `KvConfig` | `NatsConfig` | `session_bucket`, `request_bucket` and the TTLs are **EHDB KV** settings. Only the connection fields were dead. |
| `server` `coherence.rs` shell | NATS-KV-backed `CoherenceKv` | `state.rs` branches on `KvRead::Hit`/`Miss`/`Unavailable` on live paths |
| `gateway` `build_state_message` | in `playbook_state.rs` beside the NATS listener | The EHDB feed reader calls it — it was always shared |

## Two defects the removal itself surfaced

**The command-dispatch metric would have gone quiet.**
`record_command_publish` lived **only** in the NATS publish arm, so deleting
that arm dropped it entirely — no error, just a metric that stops moving. Moved
to the EHDB arm.

**`lag_poller` had already been dead in production.** It early-returned because
`nats_subscriber()` is `None` on the EHDB bus, so it woke every 5 s to do
nothing. It looked alive in the code and in the process list; it had not
reported a number since the T4 flip.

## Silent defaults turned into loud failures

Consistent with everything else this migration taught — a component that fails
quietly while the platform looks healthy is the expensive failure mode:

- A worker whose pool does not resolve **refuses to start** (was: silently join
  `shared` and claim nothing).
- A `NOETL_COMMAND_BUS` / `NOETL_EVENT_BUS` naming a removed transport logs an
  explicit "not delivered" / "no transport" (was: silent no-op / silent fall
  through to synchronous inserts).
- An empty `NOETL_EVENT_FEED_ADDR` or `NOETL_KV_ADDR` is a **gateway startup
  error** (was: fall back to NATS, which no longer exists — so the gateway would
  start and the SPA would receive nothing).

## Env renames

| Was | Now |
| :-- | :-- |
| `NATS_FILTER_SUBJECT` | `NOETL_FEED_FILTER_SUBJECT` (fallback removed) |
| `NATS_SESSION_BUCKET` / `NATS_SESSION_CACHE_TTL_SECS` | `NOETL_KV_SESSION_BUCKET` / `NOETL_KV_SESSION_TTL_SECS` |
| `NATS_REQUEST_BUCKET` / `NATS_REQUEST_TTL_SECS` | `NOETL_KV_REQUEST_BUCKET` / `NOETL_KV_REQUEST_TTL_SECS` |
| `NATS_CALLBACK_SUBJECT_PREFIX` | `NOETL_KV_CALLBACK_ID_PREFIX` |

Removed: `NOETL_NATS_URL`, `NATS_URL`, `NATS_STREAM`, `NATS_CONSUMER`,
`NOETL_REPLICA_COHERENCE=nats_kv`. Prod set none of the renamed ones, so the
rename is a no-op there.

## What is deliberately NOT done

**`async-nats` still ships in the worker.** Three subsystems still reference it:
`state_builder`'s legacy JetStream drain, the materializers' NATS arms in
`MaterializerFeed`, and `spool_runtime`'s `nats_object` backend.

They are dead — a catalog check found **0** playbooks using `kind: subscription`
and **1 test** playbook using a nats spool backend — but they are interleaved
with live code (the EHDB drain shares helpers with the NATS one; `MaterializerFeed`
is the shared adapter). Rushing them at the end of a long change is exactly how
something load-bearing goes with them. Tracked as a scoped follow-up.

**The `nats` tool kind stays for now**, for the same reason plus one of its own:
five catalog playbooks still declare it (three auth, two test). They are already
non-functional and not executed — both auth sync fast-paths are on — but removing
the kind while those rows exist turns a dormant step into a hard "unknown tool
kind" if anyone flips the sync flags off. The auth playbooks should lose their
`cache_session` steps first (the gateway populates its own cache); that is
catalog data, not code.

## Observation worth recording

The gateway's KV probe logs `ERROR: EHDB KV unreachable` if it boots while the
writer is still rolling. It is a **one-shot at startup** and the client redials
lazily, so the gateway recovers on its own — verified here, where the probe
failed at 15:58:32 and SSE then delivered 4022 frames. The log line is more
alarming than the condition; a retry-with-backoff around the probe would read
better.
