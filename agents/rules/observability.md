---
paths:
  - "repos/noetl/**"
  - "repos/server/**"
  - "repos/gateway/**"
  - "repos/worker/**"
  - "repos/cli/**"
  - "repos/tools/**"
  - "repos/travel/**"
  - "repos/gui/**"
---

# Observability — traceability, metrics, snowflake IDs

NoETL is a distributed runtime: gateway → server → NATS → worker → tools → server (event log).  When something misbehaves in production the only way to find it is the trace.  Pair this rule with [`logging.md`](logging.md) (which constrains *what* gets logged) — this rule constrains *what gets traced / measured* and *how IDs flow through the system*.

## Principle 1 — observability is part of the implementation, not a follow-up

Every new feature, every new boundary call, every new dispatch path lands **with its observability hooks in the same change set**.  Three concrete artifacts each substantial change ships:

1. **A span** (or extension of an existing span) covering the operation.  Span name should be the action verb (`event.ingest`, `command.claim`, `tool.dispatch.http`, `playbook.execute`).
2. **At least one metric** capturing what could become a bottleneck or could fail silently — counters for throughput, histograms for latency, gauges for queue depth.  Name metrics with the noun-verb shape (`noetl_events_ingested_total`, `noetl_command_claim_duration_seconds`, `noetl_nats_consumer_lag`).
3. **An execution_id correlation** — every span and metric carries `execution_id` as a label / attribute so a single playbook run can be reconstructed from end to end across gateway + server + worker + tool logs.

If a PR doesn't include these three artifacts for a non-trivial change, the reviewer asks where they went.  "We'll add observability later" is how production debugging becomes guesswork.

## Principle 2 — metrics over logs

A flood of INFO logs is **not observability**.  See [`logging.md`](logging.md).  The shape this rule enforces:

| Want to know | Use | Not |
| :---- | :---- | :---- |
| How many commands were processed last hour | counter `noetl_commands_processed_total` | grep INFO lines |
| How long the slow ones took | histogram `noetl_command_duration_seconds` | grep slow-line patterns |
| Whether the worker is keeping up with the backlog | gauge `noetl_nats_consumer_lag` | watch debug logs |
| Whether a specific dispatch failed | structured event on the playbook's event log + WARN/ERROR with `execution_id` | spam INFO from happy paths |

Counters / histograms / gauges scale.  Logs do not.  When you reach for a log line, ask: "would a counter increment + a span event tell me what I need?"

### Where metrics live

- **Rust binaries** (cli, server, worker, gateway, tools): use [`tracing`](https://docs.rs/tracing) spans + [`prometheus`](https://docs.rs/prometheus) (or an opentelemetry-rust exporter) registry exposed at `/metrics`.
- **Python server** (`repos/noetl/noetl/server`): use `prometheus_client` registry; expose at `/metrics`.
- **Local validation**: every metric must be reachable on the local kind cluster via `kubectl port-forward` so [`deployment-validation.md`](deployment-validation.md) checks include the metrics surface, not just functional behaviour.

### What to instrument first

When in doubt, instrument the **boundaries** — the places where work flows between components:

- Gateway → server HTTP calls (per route latency + status code).
- Server → NATS publish (publish rate + per-subject backlog).
- NATS → worker pull (consumer lag, claim rate, claim outcome distribution).
- Worker → tool dispatch (per tool kind: duration, error rate).
- Tool → external API (HTTP / DB / cloud-storage call durations + retry counts).
- Server event-log writes (insert rate + insert latency).

Boundaries are where bottlenecks hide.  Internal hot loops are usually CPU-bound and easier to profile reactively; cross-component calls are the ones that surprise you in production.

## Principle 3 — snowflake IDs come from the application, not the database

Identifiers that need to be available **before** the row hits the database — `execution_id`, `command_id`, `event_id` — are generated **in the calling application** using a snowflake-style algorithm.  Reasons:

1. **Spans need the id at span creation time**, not after the round-trip.  An `execution_id` issued by the server's `INSERT` arrives after the `event.ingest` span is already open, breaking the correlation.
2. **Retries are idempotent only if the id is stable across the retry**.  If the database assigns the id on first try, a retry creates a duplicate row OR a NULL id during the failure window.
3. **Cross-component coordination needs the id before publish**.  The worker must put `execution_id` on the NATS message; if the server's INSERT generates it, the publish has to wait for the INSERT, doubling the latency.
4. **Test fixtures need deterministic ids**.  Application-side generation lets tests inject seed values; database-side `gen_snowflake()` calls force a live DB even for unit tests.
5. **Sharded / multi-cluster deployments** can't agree on a single DB-side sequence.  Snowflake's `(timestamp, machine_id, sequence)` layout was designed exactly for this — keep the generation where the machine_id is naturally available (the application process).

### How to implement

Use a library, not a hand-rolled implementation.  Rust: [`snowflaked`](https://docs.rs/snowflaked) or [`sonyflake`](https://docs.rs/sonyflake).  Python: [`pysnowflake`](https://pypi.org/project/pysnowflake/) or the existing `noetl.core.ids.snowflake` helper.

The `machine_id` portion of the snowflake is derived from:

- **Worker / server**: `WORKER_ID` env var (set per pod by the deployment manifest) hashed to a 10-bit value.
- **CLI local mode**: a stable hash of `hostname()` + process pid.
- **Gateway**: pod name hash.

`timestamp` is wall-clock ms since the NoETL epoch (`2024-01-01T00:00:00Z` is fine; pick once and never change).  `sequence` increments within the same ms; reset on next ms.

### Existing database functions

`noetl.event` and `noetl.command` tables currently default `event_id` / `command_id` via a `gen_snowflake()` Postgres function.  Don't remove that function — it's the fallback for inserts where the caller didn't supply an id (e.g. ad-hoc admin SQL).  But application code should **always** supply the id explicitly and let the DB default fire only on out-of-band writes.

Per-component migration order (when removing the DB-default reliance):

1. Application generates the id (snowflake helper).
2. Span / metric uses that id immediately (before the DB call).
3. `INSERT` passes the id explicitly.
4. (Optional, later) Drop the DB-side default once all callers comply.

## Principle 4 — execution_id is the trace key everywhere

Already required by Principle 1; calling it out as load-bearing because mistakes here are corrosive:

- HTTP requests on the control plane: `execution_id` in path or query param, NOT just in body.  Easier to log + grep.
- NATS messages: `execution_id` as a header / message attribute, NOT only inside the JSON body.
- Tracing spans: `execution_id` as a span field (`tracing::info_span!("event.ingest", execution_id = %id)`).
- Metrics: `execution_id` is NOT a label on Prometheus metrics (cardinality blows up the registry).  It IS a span attribute that the metrics system can correlate via exemplars (OpenTelemetry) or trace links.
- Logs: every WARN / ERROR line includes `execution_id` in the structured field set, never just in the formatted message.

The boundary: **`execution_id` rides every wire format**.  Recipients of a message that doesn't carry one should treat that as a bug — emit a WARN, generate a synthetic id, and continue.  Don't silently drop the correlation.

## Coordination with other rules

- [`logging.md`](logging.md): constrains *what* gets logged.  This rule constrains *what gets traced + measured*.  Both apply to the same code change; reviewers check both.
- [`execution-model.md`](execution-model.md): the worker's pull loop, the gateway's stateless forwarding, the playbook's policy block — every boundary in that model is a candidate observability hook per Principle 1.
- [`deployment-validation.md`](deployment-validation.md): local kind validation now includes `/metrics` reachability for any service with new metrics in a PR.
- [`wiki-maintenance.md`](wiki-maintenance.md) Rule 2: when a new metric / span / id format becomes part of the public surface, the corresponding wiki page (server's API surface, worker's adoption page, etc.) gets the addition in the same change set.

## When this rule doesn't fire

- Pure refactors that don't change behaviour or add boundaries (the existing span / metric stays unchanged).
- Documentation-only PRs.
- Test-only PRs that don't add new code paths.

Every other substantive change ships the three observability artifacts.

## History

Codified 2026-05-30 after standing instruction:

> embed traceability and observability everywhere possible to be able
> to debug and analyze in runtime. … we should not generate tons of
> logs but we should be able to capture detailed metrics — flow and
> components bottlenecks, latencies in runtime. by the way, it's a
> good idea to generate snowflake ids on the application side, and
> do not rely on database functions to generate it.
