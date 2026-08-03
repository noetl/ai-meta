# EHDB-only sustained-load soak in local kind

Validates the EHDB-only platform under sustained concurrency, in `kind-noetl`
only. No prod, no gcloud.

The EHDB-only platform (server v3.60.2 / worker v5.91.2 / gateway v3.7.1 /
ehdb `ddb7ac9`, NATS deleted 2026-08-01) had only ever been validated with ~50
executions on an idle cluster. The events bus — SSE fan-out, three
independently-cursored materializer groups, the KV face at :9107, the WAL
fan-out face at :9108 — had never seen concurrency, and there is no NATS
fallback to fall back to any more.

## Why the gate is paired evidence, never an execution count

Every defect the NATS deletion produced failed **silently while executions
still completed**. Two from
[`211-t3-events-migration/EHDB-ONLY-RESULT.md`](../211-t3-events-migration/EHDB-ONLY-RESULT.md)
are worth restating, because they are the reason this rig exists:

- `should_publish` required a NATS connection. Removing `NOETL_NATS_URL` made
  the gate false for every event, so the server quietly fell back to
  synchronous `insert_rows`. Nothing errored. Executions completed, the durable
  log was written, and the entire CQRS publish path was inert with the feed
  cursor flat.
- The off-server state builder was an uninventoried **fourth** consumer of
  `noetl_events`. With NATS gone every orchestrate returned `WAL chain
  incomplete`, executions stalled at RUNNING, and no error appeared anywhere.

A green execution count would have signed off on both. So the pass condition
pairs `published` with `projected` with the per-group cursors:

```
published == projected
  AND all three group cursors advanced by that same delta, ending at lag 0
  AND ehdb_events_cursor_errors == 0
  AND ehdb_l0_out_of_order_appends == 0
  AND 0 dup ids, 0 publish errors
  AND every SSE subscriber saw every frame
```

`noetl_events_materialized_total` is **not** a substitute for
`noetl_events_projected_total` — it counts the `events/materialize` sink this
deployment does not use, so it reads 0 forever.

## Files

| File | What |
|---|---|
| `ehdb-only-kind.yaml` | PVCs + the writer Service carrying all six events faces (incl. :9107 KV and :9108 WAL, which appear in no manifest anywhere else) |
| `bring-up.sh` | Patches the kind deployments into the EHDB-only topology. Idempotent, refuses any non-kind context. |
| `soak.sh` | `./soak.sh <rounds> <execs-per-round> [concurrency]` — sustained bursts with live SSE subscribers, drains to terminal state per round, emits the paired-evidence verdict |
| `writer-restart.sh` | `./writer-restart.sh graceful\|hard` — restarts the writer **mid-burst** and measures the unsealed-tail loss |

## There is no EHDB-only IaC — this rig had to reconstruct it

`repos/ops` `origin/main` contains **zero** occurrences of
`NOETL_COMMAND_BUS`. The prod EHDB-only topology was produced imperatively with
`kubectl set env` / `kubectl patch` during the 2026-07-31/08-01 cutover and
never written back, so there was nothing to redeploy from. `bring-up.sh` is
imperative for the same reason, and deliberately mirrors how prod was actually
cut over.

That gap is the real IaC debt — bigger than
[noetl/ops#241](https://github.com/noetl/ops/pull/241), which only ever covered
the command-bus writer and has since been overtaken by events.

## Deliberately broader than prod

Prod runs only **two** materializer groups: `NOETL_STATE_BUILDER=server`
disabled the off-server state-builder subsystem and took the state materializer
with it ([noetl/ai-meta#217](https://github.com/noetl/ai-meta/issues/217)).

This rig enables all three groups plus the state-builder WAL drain in **shadow**
mode. Shadow is the point for the drain: it exercises the chain-walk and puts
the :9108 fan-out face under real load with no drive impact, so the face is
covered without putting the #217 gap on the execution path.

## Kind's ceiling — what this can and cannot prove

Kind's worker pool tops out far below the prod bus ceiling. This is the same
reason [noetl/ai-meta#205](https://github.com/noetl/ai-meta/issues/205) could
not be reproduced here: the kind pool sustains ~28–131 cmd/s against a bus
ceiling near ~1000 cmd/s, so **a saturating burst measures the pool, not the
bus.**

This soak therefore proves **correctness under concurrency** and **shutdown
behaviour**. It does not and cannot prove prod throughput or dispatch latency.
See the report on
[noetl/ai-meta#209](https://github.com/noetl/ai-meta/issues/209) for exactly
what still requires the prod soak.

## Ports

```
9100 cmdbus ingest   9103 events ingest    9106 events lag/metrics
9101 cmdbus claim    9104 events claim     9107 KV
9102 cmdbus lag      9105 events SSE       9108 WAL fan-out
```

Naming trap: `NOETL_COMMAND_SHARD_COUNT` and `NOETL_EVENT_SHARD_COUNT` carry no
`_BUS_`, while every bind does.

## Metrics, and where they live

| Gate | Metric | Endpoint |
|---|---|---|
| Published | `noetl_ehdb_events_published_total{event_type}` | server `:8082/metrics` |
| Publish errors | `noetl_ehdb_events_publish_errors_total` | server `:8082/metrics` |
| Projected (durable-log ground truth) | `noetl_events_projected_total` | server `:8082/metrics` |
| Per-group cursor / lag | `ehdb_events_group_committed{group}` / `ehdb_events_group_lag{group}` | writer `:9106/metrics` |
| Cursor-persist errors | `ehdb_events_cursor_errors` | writer `:9106/metrics` |
| Append integrity | `ehdb_l0_out_of_order_appends`, `ehdb_l0_appends` | writer `:9102/metrics` |
| Command lag | `ehdb_feed_subject_lag{subject}`, `ehdb_feed_shard_lag{shard}` | writer `:9102/metrics` |
| Restart facts | `ehdb_feed_shard_resume_{from,tip,stored,replay_records}` | writer `:9102/metrics` |

## Measurement traps already handled

- **Two soaks against one cluster** interleave and read each other's in-flight
  commands as failures. `soak.sh` takes a `mkdir` lock.
- **Lag 0 means the bus drained, not that playbooks finished.** Each round
  polls to terminal state across all three group lags *and* the command-bus
  shard lag.
- **A restart on an idle writer proves nothing.** `writer-restart.sh` restarts
  mid-burst, because the failure mode is records acked in the window around the
  seal.
- **Execution completion hides writer loss.** The orphaned-command guardrail
  ([#171](https://github.com/noetl/ai-meta/issues/171)) re-issues lost commands
  ~30s later, so executions complete either way. The loss is measured as
  `l0_appends at kill` minus the reopened engine's tip, not from execution
  outcomes.
