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
