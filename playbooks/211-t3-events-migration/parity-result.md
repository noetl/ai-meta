# Shadow parity proof — shastaratech prod, 2026-07-31

`NOETL_EVENT_BUS=shadow` on `noetl-server-rust` v3.60.0; events writer host
enabled on `noetl-cmdbus-writer-0` (worker v5.86.0). **All four consumers stayed
NATS-sourced throughout** — this proves the publish path only.

Load: 60 executions of `fixtures/playbooks/hello_world`, concurrency 12,
60/60 accepted, 0 errors.

## Gate 1 — publish parity

| Signal | Value |
| :-- | --: |
| NATS `noetl_events` message delta | **1140** |
| Server `noetl_event_ingest_published_total` delta | **1140** |
| Server `noetl_ehdb_events_published_total` delta | **1140** |
| Server `noetl_ehdb_events_publish_errors_total` | **0** |
| EHDB group cursor-persist errors | **0** |

Per-`event_type` distribution identical on both buses:

| event_type | NATS | EHDB |
| :-- | --: | --: |
| `call.done` | 180 | 180 |
| `command.claimed` | 180 | 180 |
| `command.completed` | 180 | 180 |
| `command.issued` | 180 | 180 |
| `command.started` | 180 | 180 |
| `playbook.completed` | 60 | 60 |
| `playbook_started` | 60 | 60 |
| `step.enter` | 120 | 120 |

**PARITY GATE: PASS.**

## Gate 2 — projection parity (would EHDB materialize identical rows?)

The brief's harder question: not just "did the records arrive" but "would the
EHDB path have written the same `noetl.event` rows". Read the EHDB feed back
through the **SSE broadcast face**, which holds its own per-subscriber cursor —
so this read did **not** disturb any materializer group's position.

| Check | Result |
| :-- | :-- |
| Records read off the EHDB feed | **1140** (all parseable, all carry `event_id`) |
| `noetl.event` rows written for the window (NATS-fed) | **1140** |
| `event_id` sets | **identical** — 0 only-on-EHDB, 0 only-in-durable |
| Field comparisons (`event_type`, `status`, `node_name`, `created_at`, `error`, `result`) | **5460**, 0 semantic mismatches |
| `event_type` distribution | identical across all 8 types |
| Feed ordering | **strictly ascending**, contiguous `1..1140`, **no gaps** |

**PROJECTION-PARITY GATE: PASS.**

### The one apparent mismatch, and why it is not one

A first pass flagged 1/5460 on `created_at`:

```
EHDB    2026-07-31T13:44:53.468999687Z
durable 2026-07-31T13:44:53.469Z
```

That was the comparator truncating where Postgres rounds. Measured properly, the
**maximum** delta across all 1140 events is **1.0 µs** — nanosecond→microsecond
narrowing applied by Postgres `timestamptz` on ingest. It is applied identically
on both transports (the NATS-fed row carries the same narrowed value), so it is
not a difference between the buses. Recorded because a future run will see it
again and should not re-litigate it.

## Coverage limits (stated plainly)

- The execution-detail read API surfaces 7 of `noetl.event`'s columns, so the
  row comparison covers `event_type`, `status`, `node_name`, `created_at`,
  `error`, `result`. `execution_id`, `catalog_id`, `node_id`, `node_type`,
  `parent_event_id`, `prev_event_id`, `parent_execution_id` and `worker_id` were
  **not** compared row-by-row — they ride the same byte-identical payload the
  publisher sends to both buses, but that is an argument, not a measurement.
- This window was 1140 events over ~35 s on an otherwise idle cluster. It proves
  correctness, not behaviour under sustained load or contention.
- The EHDB groups were never consumed (lag 1140 on all three at rest), which is
  the intended shadow posture but means the **consume** path is unproven in prod.

## Prod state at the end of this run

| Workload | Setting |
| :-- | :-- |
| `noetl-server-rust` | v3.60.0, `NOETL_EVENT_BUS=shadow` |
| `noetl-cmdbus-writer-0` | v5.86.0, `NOETL_EVENT_BUS_HOST=true` (9103/9104/9105/9106) |
| `noetl-worker-system-pool` (+`-shard1`) | `NOETL_MATERIALIZER_SOURCE` **unset → nats** |
| `gateway` | `NOETL_EVENT_SOURCE` **unset → nats** |
| NATS | **untouched**; all three materializers draining, 0 unprocessed |

Command bus unaffected — the writer resumed from persisted cursor 31351,
`origin=persisted`, no replay.

**HOLD.** No consumer cut over. NATS remains authoritative.
