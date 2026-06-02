# NoETL Data Access Boundary

A corollary to the [Execution model](execution-model.md)'s
"workers are atomic compute blocks" shape, made explicit
because it has bite at the platform-scale boundary.

## The rule

**NoETL platform data is accessible via the NoETL server API
only.** Workers — including the system worker pool — talk to
the server's HTTP API for any read or write to NoETL-owned
tables.

NoETL-owned tables today (the rule applies to all of them):

- `noetl.event` — the durable event log
- `noetl.command` — the command queue
- `noetl.execution` — execution records
- `noetl.outbox` — transactional outbox for NATS publish
- `noetl.catalog` — playbook + tool + resource catalog
- `noetl.credential` — credential store
- `noetl.keychain` — keychain entries
- `noetl.runtime` — worker registration / heartbeat / runtime contract
- Any future `noetl.*` table.

The rule covers both reads and writes.  Workers query catalog
entries via `GET /api/catalog/...`, not `SELECT FROM noetl.catalog`.
Workers emit events via `POST /api/events`, not
`INSERT INTO noetl.event`.

## Why

Three reasons, in order of weight:

### 1. Connection pool isolation

Workers scale on backlog.  KEDA on NATS consumer lag pushes
the Rust worker pool from 1 → 20 pods routinely; the Python
worker pool can reach 50+.  If each worker holds a Postgres
connection from a shared pool, the math collapses:

- Postgres max_connections = 100 (typical Cloud SQL tier).
- Server pool: 8 connections per replica.
- Worker pool: 1 connection per worker × 50 workers = 50.
- Two server replicas + 50 workers = 66 connections, near the
  cap; one slow query and the pool is full.
- Server API can't acquire a connection → API returns 503 →
  workers' HTTP calls to the API time out → workers retry →
  more load → more connections → cascade.

The fix: **only the server holds connections to the platform
DB**.  Workers hold an HTTP client to the server.  Connection
math becomes: 8 server connections per replica, independent of
worker count.  HTTP connection limits at the load balancer are
the natural throttle.

### 2. Sharding readiness

NoETL is designed to be shardable — future:

- N server replicas, each owning a slice of executions
  (e.g. `execution_id % N`).
- A gateway / load balancer routes API calls to the right
  shard based on `execution_id` in the path or header.
- The shared DB instance gets sharded later (PostgreSQL Citus,
  Vitess-style, or per-shard separate DB).

If workers talk to the DB directly, sharding requires every
worker to:
- Know which shard owns each execution.
- Hold connections to all shards.
- Route reads/writes by execution_id.

If workers talk to the server API, sharding is **transparent
to workers**.  The server (or the gateway in front of it)
handles shard resolution; workers just call the API.

Sharding readiness is a strict prerequisite for multi-region,
multi-tenant scale.  Direct-DB workers lock it out.

### 3. Single point of consistency

The server enforces:

- **Schema migrations** — workers don't need to know the
  current schema version; the API surface is stable across
  migrations.
- **Audit logging** — every write through the API gets logged;
  direct DB writes bypass.
- **RBAC** — the API checks the caller's identity against the
  resource; direct DB writes bypass.
- **Response-boundary credential scrubbing**
  (`scrub::scrub_in_place`) — the API masks credentials in
  responses; direct DB reads expose unredacted values.
- **Validation** — the API rejects malformed events; direct
  DB writes can corrupt the log.

Distributing this logic across workers (so each worker can
talk to DB directly while honoring the same invariants) is
~the whole noetl-server.  Not a viable architecture.

## The exception — external subsystems

The rule applies to **NoETL platform data**.  It does NOT
apply to **external systems** that NoETL integrates with.

A playbook step may use `tool: postgres`, `tool: http`,
`tool: snowflake`, etc. against an external resource:

- A tenant's own Postgres database for their domain data.
- A third-party API (Duffel, Amadeus, OpenAI).
- An IdP (Auth0, Okta, SAML).
- An object store (GCS, S3) holding tenant data.

These are "playbook acts as client to external system" — the
normal NoETL pattern.  The keychain authenticates to the
external system; the tool dispatches the call; the result
lands in the playbook's data flow.

### The auth playbook exception (canonical case)

`system/auth` is the textbook example.  It talks to Auth0 /
Okta / SAML — those are **external** to NoETL.  Calling
`POST https://<tenant>.auth0.com/oauth/token` is the right
shape.  Forcing it through the noetl-server API would add a
hop with no benefit (the server isn't the source of truth for
Auth0 tokens — Auth0 is).

Other system playbooks follow the same pattern when their job
is external:

- `system/credential_rotate` — talks to GCP Secret Manager,
  AWS Secrets Manager, Vault.  External; direct.
- `system/notify_alert` — talks to PagerDuty, OpsGenie, Slack.
  External; direct.

But when a system playbook's job is **manipulating NoETL
state**, the rule applies:

- `system/outbox_publisher` — claims rows FROM noetl.outbox.
  Must go through the server API: `POST /api/internal/outbox/claim`,
  `POST /api/internal/outbox/mark-published`.  Not
  `tool: postgres` against `noetl.outbox`.
- `system/projector` — writes TO noetl.event.  Must go through
  the server API: `POST /api/internal/events/project`.  Not
  `tool: postgres` against `noetl.event`.
- `system/scheduled_cleanup` — TTL enforcement on noetl-owned
  tables.  Server API only.

## Server-side implications

This rule requires the server to expose **internal-only API
endpoints** that the system worker pool can call.  These don't
exist in the Python server today because today's Python
publisher + projector hit the DB directly.

Suggested initial inventory (Phase 1 of [Umbrella: System Pool
Design](https://github.com/noetl/ai-meta/wiki/Umbrella-System-Pool-Design)):

| Endpoint | Replaces direct DB access by |
|---|---|
| `POST /api/internal/outbox/claim?limit=N` | Python publisher's `claim_outbox_batch` |
| `POST /api/internal/outbox/mark-published` | Python publisher's `mark_outbox_published` |
| `POST /api/internal/outbox/mark-failed` | Python publisher's `mark_outbox_failed` |
| `POST /api/internal/events/project` | Python projector's batch INSERT |
| `GET /api/internal/outbox/pending-count` | KEDA scaler trigger source for the system pool |

Auth: gated by a service-account token only the system worker
pool's K8s ServiceAccount carries.  User playbooks can't call
these endpoints (route returns 403).

Per `agents/rules/observability.md` Principle 1, each endpoint
ships with its span + metric + `execution_id` correlation in
the same change set.

## Decision tree for a new playbook

When designing a system playbook (or reviewing one), ask:

1. **Does this playbook touch `noetl.*` tables?**
   - Yes → all such touches go through server API.
   - No → tool kinds direct against external resources.

2. **Does the API have the endpoints this playbook needs?**
   - Yes → use them.
   - No → file a sub-issue against `noetl/noetl` (Python
     server) or `noetl/server` (Rust port) to add the endpoint
     BEFORE writing the playbook.  Don't ship a playbook that
     can't run because the API isn't there yet.

3. **Is auth needed for the API call?**
   - Always yes for `/api/internal/*` routes.  Use the system
     pool's service account token.

## Coordination with other rules

- [`execution-model.md`](execution-model.md) — establishes the
  gateway / worker / playbook / cache / event-log shape.  This
  rule extends the **data access rule** in that file with the
  explicit "workers, including system workers, never reach
  noetl.* directly" corollary.
- [`observability.md`](observability.md) — every new
  `/api/internal/*` endpoint ships with the three artefacts
  (span + metric + execution_id).
- [`issue-tracking.md`](issue-tracking.md) — sub-issue against
  the server repo when an endpoint is missing for a playbook
  that needs it.

## History

Codified 2026-06-02 (afternoon) after standing instruction:

> the data that owned by noetl server should be accessable via
> noetl server api only. and updated via api. System workers
> should talk to server api to get and modify noetl data. why
> - because workers can scale and block database connection
> pool and lock server api itself. Also sharding of noetl
> server instances should be considered. That rule does not
> apply to auth playbook as it is an external subsystem for
> noetl core.
