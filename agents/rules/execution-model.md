---
paths:
  - "**"
---

# Execution Model — the foundational shape

Before designing any feature, integration, deployment change, or
operational fix on NoETL, measure the proposal against this page.

**Full reference** (engineer-facing):
[`repos/docs/docs/architecture/ephemeral_blueprints.md`](https://github.com/noetl/docs/blob/main/docs/architecture/ephemeral_blueprints.md)

## The shape

- **Gateway = gatekeeper only.** Session auth, authorization, SSE
  / callback delivery, subscription routing, request-id
  correlation. Never reads or writes domain data on behalf of a
  client.
- **Workers = atomic compute blocks.** Stateless. Claim a block,
  hydrate inputs from the shared cache, execute one tool, write
  outputs to the cache, emit boundary events, release the slot.
- **Playbooks = ephemeral blueprints.** Control flow and policy
  for a request. Invoked on demand; no resident state between
  invocations beyond what the event log records.
- **Shared cache = state vehicle between blocks.** Arrow IPC,
  scoped to `execution_id` + step. Rebuildable from the event
  log.
- **Event log = source of truth.** Append-only; immutable. Replay
  reproduces state for any past time.

## Data access rule

Any data touch (read, write, projection, subscription, third-
party API) happens inside a playbook step under that playbook's
policy block. Clients never reach a database directly. The
gateway never reaches a database to satisfy a client request.

If your proposal places data-touch logic in the gateway or in
the client, the proposal is in the wrong shape.

### NoETL-owned data: server API only

A corollary that applies when the data target is the **NoETL
platform itself** (the `noetl.*` schema — event log, command
queue, catalog, outbox, credentials, runtime registration):
**only the NoETL server has direct DB access.**  Workers
(including the system worker pool) call the server's HTTP API
for these tables.  Reasons:

1. **Connection pool isolation** — workers scale 1→50+ on
   backlog; if each holds a Postgres connection the pool runs
   out and the server's own API can't acquire one.
2. **Sharding readiness** — server may shard by `execution_id`
   later; API boundary makes shard routing transparent to
   workers.
3. **Single point of consistency** — the server enforces
   schema migrations, audit logging, RBAC, scrub.  Distributing
   these across workers is ~the whole server.

The exception: **external-subsystem playbooks** (auth, credential
rotation, alerting) that integrate NoETL with Auth0 / Okta /
Vault / PagerDuty / Slack / etc. go direct because the target
isn't NoETL data, it's an external system.

Full rationale + the new internal API surface this requires:
[`agents/rules/data-access-boundary.md`](data-access-boundary.md).

## Secrets and credentials rule

Business-logic secrets do **not** live in worker or gateway
environment variables.

- **Business-logic credentials** (third-party API tokens like
  Auth0 / Duffel / Amadeus / OpenAI / Anthropic, tenant database
  DSNs, OAuth client secrets, signing keys, encryption keys —
  anything a playbook step needs to act against an external
  system) live in the **NoETL keychain** and are referenced by
  credential alias inside playbook steps, e.g.
  `auth: "{{ db_credential }}"`. The keychain can resolve from
  secret managers, wallets, or other secret storage.
- **Platform / runtime credentials** (the worker's own NATS
  connection, its own state DB, the gateway's session-signing
  key, internal mTLS) are runtime, not business logic. They may
  live in pod env / configmaps / k8s Secrets at the platform
  layer.
- **Already-in-place trust** — GKE workload identity, IAM
  service accounts, established SSH tunnels — can be used
  as-is from worker / gateway processes. They are already
  authenticated at the pod or process boundary; do not
  re-mediate through the keychain.

If a proposal adds a third-party API token, a tenant database
DSN, or any other business-logic secret to a worker or gateway
env var, push back. The credential goes in the keychain; the
playbook references it by alias; the tool resolves it at step
execution time.

HTTP responses that surface execution state, variables, events, or
result payloads must mask resolved credential values before they leave
the server. See the noetl wiki's
[Secrets and Response Redaction](https://github.com/noetl/noetl/wiki/secrets-and-redaction)
page for the response-boundary contract.

## Ephemeral execution rule

NoETL does not retain persistent per-tenant AI-agent processes
or MCP server instances. An "AI agent" is a directed sequence
of blocks; an "MCP server" is a playbook in the catalog. Both
are dispatched on demand, run on the worker pool, and release
their slots when their blocks complete.

Workers scale on real backlog (KEDA reads NATS JetStream
consumer lag), not on expected concurrent agents.

## Callback / hook rule

A block must not hold a worker slot waiting for an external
operation that takes more than a few seconds. The pattern:

1. The block captures `execution_id` + callback subject /
   webhook URL.
2. The block returns; the worker slot frees.
3. The external system, when ready, sends a callback carrying
   the `execution_id`.
4. The callback handler applies the payload to the latest
   recorded state for that `execution_id` and emits the
   resume event.
5. The next block claims off NATS and continues atomic
   execution from the recorded state.

Time in the external system is free. Worker slots are only
held while blocks actually run.

## Where to put new work

Decision tree for any new feature:

1. **Initiates work, gates access, or routes responses?** →
   gateway. Stay stateless beyond session / subscription
   bookkeeping.
2. **Touches data, calls an external API, or composes
   multiple operations under business rules?** → a playbook
   in the catalog. Declare the policy block; tools execute
   the steps.
3. **Executes a unit of computation (transform a payload,
   run a query, invoke an LLM)?** → a worker tool. Add a
   new tool kind only if no existing one fits.
4. **Needs shared state between blocks?** → the shared
   cache. The event log records what happened; the cache
   carries what the next block reads.
5. **Waits on something external?** → callback / hook
   pattern. Never hold a slot for the wait.

## Why this is load-bearing

The shape is the platform's "knowhow" for cost-effective and
performance-optimized agentic AI computation. Specifically:

- No persistent agent infra to monitor or pay for between
  requests.
- Adding integrations is a catalog row, not a new
  deployment.
- Workers can be added, removed, or restarted freely without
  data loss; state lives in the cache + event log.
- Audit, replay, retry, and schema evolution have one home
  (the playbook policy block).

When reviewing a proposal, the question to ask is:
"does this honor the boundary?" If not, push back before
the implementation lands.

## Related rules

- [`agents/rules/handoffs.md`](handoffs.md) — file-based
  cross-agent coordination uses the same boundary
  discipline.
- [`agents/rules/ops-deploy.md`](ops-deploy.md) — operational
  manifests live in `noetl/ops/ci/manifests/`; the
  Helm chart is the GKE deploy spec. Both are consequences
  of this model.
- [`agents/rules/writing-style.md`](writing-style.md) —
  prose for these docs.
