# RFC: Mode interop over a live topology, and first-class bidirectional AI/MCP playbooks

- **Status:** Draft. Phase 1 (noetl/server#560) is in review, flag-gated, and OFF by default. Nothing is armed in prod.
- **Date:** 2026-11-07
- **Decision record:** [`docs/decisions/2026-11-07-agent-mcp-tool-kinds-flag-gated.md`](../decisions/2026-11-07-agent-mcp-tool-kinds-flag-gated.md)
- **Related:** noetl/ai-meta#256 (registration rejects unknown tool kinds), #447 (resource type ≠ tool kind),
  #455 (D8 runtime registry and discovery), #43 (container callback), #90 (subscriptions),
  #246 (provider `isError`), #303 (auth gate), #330 (worker noetl-tools hold).
- **Docs it extends:** noetl/docs `docs/architecture/deployment_modes.md` (CLI / daemon / distributed),
  noetl/ops ADR-0001…0007 (NoETL-as-IaC), noetl/ehgraph `docs/wiki/{API-and-MCP,Embedding}.md`.

Code citations are against `main` on 2026-11-07: server `7ab70d8`, worker `58a2c7a`,
cli `3d8c501` (v5.5.0), tools `main` (published 4.4.0), ehgraph `3cb4ab3`, ops `f9855a1`.

---

## 0. Summary

NoETL runs one DSL in three modes: **CLI** (`noetl run -r local`), **daemon** (`noetl subscribe`)
and **distributed** (server + worker pools). Today the modes connect in one direction only. A
daemon can `--dispatch server` and a CLI run can `noetl push` its history, but nothing can
call *into* a daemon or a CLI, and no mode can find out what the others can run.

AI/MCP has the same one-directional shape. A playbook can call an MCP server, but only in the
CLI and the legacy Python runtime. The Rust server rejects `tool.kind: mcp` and `tool.kind: agent`
at registration. Nothing can call a NoETL playbook *as* an MCP tool or *as* an agent.

This RFC proposes:

1. **Topology in two layers.** The existing D8 runtime registry (`/api/runtime/*`) answers "who
   is up" with a lease. The embedded ehgraph `noetl-cluster` graph answers "what can each
   member run, and how is it reached". **The server is the only writer.** Members register
   through the server API, which keeps the data-access boundary and ehgraph's single-writer
   rule (E2).
2. **One call envelope for every mode pair** (`RemoteTask`). It is delivered by HTTP push when
   the target is reachable, and by a server-held **inbox** that the target long-polls when it is
   not, such as an edge daemon behind NAT. Results come back through a **generic callback**. This
   generalises the container tool's `pending_callback` and `/api/internal/container-callback`
   path (#43).
3. **`mcp` and `agent` as native tool kinds** on the server. The worker already executes `mcp`
   through noetl-tools' `McpTool`. `agent` needs the worker to register `AgentTool` first, and
   later needs an orchestrator-driven, turn-by-turn agent loop.
4. **Playbooks exposed as MCP tools and as agents.** The server gets an MCP endpoint whose
   `tools/list` is the set of exposed playbooks the caller may execute, and whose `tools/call`
   is `/api/execute`. Long runs return a handle and push progress and completion. An MCP server
   can be authored as a bundle of playbooks.
5. **AI coordination as an ordinary playbook.** An agent's tools are topology discovery (ehgraph
   already speaks MCP) plus a dispatch tool. Every AI-initiated action is an execution, so it
   lands on the event log.

**Phase 1 (landing now):** the server accepts `kind: mcp` and `kind: agent` behind two
independent flags, `NOETL_TOOL_KIND_MCP` and `NOETL_TOOL_KIND_AGENT`. Both are OFF by default.
With a flag off, behaviour is unchanged: registration rejects the kind with the #256 message,
and execute fails the same way as today.

---

## 1. Current state, grounded

### 1.1 The three modes and how they connect today

| Mode | Entry point | Control loop | Events | Reachable from the others? |
|---|---|---|---|---|
| CLI | `noetl run -r local` | CLI's in-process interpreter (`cli/executor`) | optional Feather buffer | no |
| Daemon | `noetl subscribe <spec>` (`cli/src/subscribe/mod.rs`) | same interpreter, re-entered on every trigger | JSONL (`--events`) | no |
| Distributed | `/api/execute`, gateway, catalog subscriptions | `noetl-server` + worker pools | EHDB event log | yes, over HTTP (`/api/*`) |

Existing bridges, all **upward** (toward the cluster):

- `noetl subscribe --dispatch server` POSTs each trigger to `/api/execute`
  (`ServerDispatcher`, `cli/src/subscribe/dispatch.rs:165`).
- `noetl push` sends a CLI execution's Feather events to `/api/events/batch`, gated by
  `NOETL_EVENTS_ARROW_INGEST` (server #559).
- `ExecuteRequest.parent_execution_id` (`server/src/handlers/execute.rs:16-54`) links a child
  execution to its parent, but it is the only cross-execution link.

Nothing goes **downward** or **sideways**. The cluster cannot invoke a daemon, a daemon cannot
invoke another daemon, and a CLI cannot be invoked at all.

**Subscription sources differ between modes.** The server's registration allowlist is
`["pubsub","nats","kafka","webhook"]` (`server/src/services/catalog.rs:475`). The CLI and
noetl-tools also implement `timer` (`tools/src/tools/source/timer.rs`; parsed at
`cli/src/subscribe/spec.rs:238`). So a timer subscription runs only as a daemon, and cannot be
registered in the cluster catalog today.

### 1.2 Topology and discovery that already exist

**D8 runtime registry (liveness).** `server/src/runtime_registry.rs`, gated by
`NOETL_RUNTIME_REGISTRY` (`:51`), with TTL leases (`NOETL_RUNTIME_TTL_SECS`) and a heartbeat
floor. Routes are in `server/src/handlers/runtime_topology.rs`:

- `GET /api/runtime/topology` returns live registrations grouped by kind. It answers `503`
  when the registry is off, never an empty `200`.
- `GET /api/runtime/watch?after=N` is a poll-based change feed with a resume cursor.
- `POST /api/runtime/register` is an idempotent register-or-renew of `{kind, id, contract}`.
- `POST /api/runtime/deregister` is an optional early exit. Correctness rests on the lease
  expiring.

The routes are mounted behind the #303 auth gate (`main.rs:469`, layered at `:963`), because
they *enumerate*. `kind` is the ehdb `RuntimeKind` enum. `parse_kind` (`runtime_registry.rs:272`)
accepts `server | gateway | ehdb | worker | playbook | execution`. **There is no `cli` or
`daemon` kind.** `contract` is a self-advertised version string and never holds secrets.

**ehgraph `noetl-cluster` (topology graph).** It is embedded in the server
(`server/src/ehgraph_embedded.rs`, `NOETL_EHGRAPH_EMBEDDED=true`, mounted at
`/ehgraph/noetl-cluster`). Its properties:

- A durable change log and versioned snapshots.
- Typed nodes and edges with `origin`, `source`, `first_seen`/`last_seen`, soft-deactivate, and
  `not_seen_since` sweeps (`ehgraph/crates/ehgraph-core/src/model.rs:89-160`).
- Per-namespace bearer grants (`ehgraph/crates/ehgraph/src/auth.rs`).
- **It already speaks MCP.** `POST /mcp` serves `tools/list` and `tools/call` over
  `graph.upsert | graph.deactivate | graph.query | graph.neighbors | graph.subgraph | graph.path | graph.session.*`
  (`ehgraph/crates/ehgraph-api/src/dispatch.rs:110-127`, `docs/wiki/API-and-MCP.md`).
- It is registered as a catalog `kind: Mcp` resource, `mcp/ehgraph/noetl-cluster`
  (`ehgraph/playbooks/automation/agents/ehgraph/resources/ehgraph-noetl-cluster.yaml`).
- It is a single writer by declaration (E2). Only a single-replica host may embed it.

**No one writes the cluster topology into ehgraph today.** The deployment-modes doc lists "the
ehgraph topology writer" as missing for IaC Phase 1.

### 1.3 Why `agent` and `mcp` are rejected

There are **two "kind" namespaces** (#447):

- **Resource type** is a document's top-level `kind:`. `Mcp` and `Agent` are valid resource
  types, for example `ops/automation/agents/kubernetes/templates/mcp_kubernetes.yaml` is a
  `kind: Mcp`.
- **Tool kind** is `tool.kind` inside a step. Its authority is
  `noetl_orchestrate_core::playbook::ToolKind`, a 25-variant enum
  (`server/orchestrate-core/src/playbook.rs:48`, `ALL` at `:93`).

`agent` and `mcp` are **not variants**. Since #256, registration validates every step's tool
kind, including the list form and nested steps, against `ToolKind::parse`, which uses serde as
its oracle (`playbook.rs:123`). Unknown kinds are rejected with the step named:

- `validate_tool_kinds` at `server/src/services/catalog.rs:571`, called at `:107`;
- tests at `catalog.rs:998` and `playbook.rs:1796`, which name `agent` and `mcp` explicitly.

The rejection is **not** a policy against AI. It is a truth-in-registration rule: before #256,
`kind: agent` and `kind: mcp` *registered* and then failed at execute with
`data did not match any variant of untagged enum ToolDefinition`. Six live paths had been dead
since they were written (#252, #256). The kinds were absent because the Rust server had nothing
to run them with.

**That premise is now half false:**

| | Server (`ToolKind`) | Worker (noetl-tools `=4.0.1`, `worker/Cargo.toml:268`) | CLI (noetl-tools `4.4`) |
|---|---|---|---|
| `mcp` | rejected | **`McpTool` is registered** (`create_default_registry`, tools v4.0.1 `src/tools/mod.rs:108`) and the worker dispatches by kind string | executes |
| `agent` | rejected | **absent.** `AgentTool` arrived in tools 4.1.0 and is **not** in `create_default_registry` in any version. The worker is also held at 4.0.1 (#330). | executes `Tool::Agent` turn by turn with sub-playbook tools (`cli/executor/src/playbook.rs:511`) |

So `kind: mcp` is blocked **only** by the server enum. `kind: agent` is blocked by the server
enum **and** by the worker.

**Live consequence.** `ops/automation/agents/kubernetes/runtime.yaml` (`metadata.agent: true`,
step `call_mcp` with `tool.kind: mcp`) cannot register on the Rust server. The helm values
(`ops/automation/helm/noetl/values.yaml:519`) still tell operators to call
`tool: kind: mcp server: mcp/ollama`.

### 1.4 The worker's MCP handling today

- **Transport.** `McpTool` (`tools/src/tools/mcp.rs`) does JSON-RPC 2.0 over HTTP. It calls
  `initialize` to obtain `Mcp-Session-Id`, then `tools/call`, `tools/list` or a passthrough
  method.
  - The endpoint comes from `endpoint`/`url`, or from `server` through
    `NOETL_MCP_<SERVER>_ENDPOINT`.
  - **There is no `Authorization` support.** The request headers are content-type and session
    only (`mcp.rs:502-516`).
  - `server: mcp/<catalog path>` is **not** resolved against a catalog `kind: Mcp` resource in
    Rust. That was legacy-Python behaviour.
- **Errors.** `provider_error_summary` (`worker/src/executor/command.rs:1760`) finds MCP
  `isError: true` anywhere in a result, up to a depth bound, and logs and counts it.
  `NOETL_PROVIDER_ERROR_TERMINATES` (`:3494`, default **off**) turns it into a step failure,
  globally for every tool.
- **Async completion.** A tool can set `ToolResult.pending_callback = Some(true)`
  (`tools/src/result.rs:109`). The worker then skips its own `call.done`. The terminal event
  arrives later through `POST /api/internal/container-callback/{execution_id}/{step}`
  (`server/src/handlers/container_callback.rs`), which is idempotent, answers 202 on stale
  callbacks, and keeps stale counters. Only `container` uses this path today.

### 1.5 Nothing exposes a playbook as MCP or as an agent

- The gateway states it plainly (`gateway/src/main.rs:494,575`): MCP servers are reached by
  worker tool execution, and "Agent and MCP activity is executed by NoETL playbooks/workers,
  not by Gateway".
- No server route serves `tools/list` or `tools/call`.
- `metadata.agent: true` and `metadata.capabilities` on a playbook (ops `runtime.yaml`) are
  descriptive only.
- The only MCP *server* in the stack is ehgraph's. It is the design template for §3.3.

---

## 2. Thread 1: the three modes interoperate

### 2.1 Topology model: liveness plus capability

There are **two layers with different jobs**. Neither replaces the other.

| Layer | Store | Question | Write path | Freshness |
|---|---|---|---|---|
| Liveness | D8 runtime registry | Is member *X* up right now? | `POST /api/runtime/register` (lease renew) | TTL lease |
| Capability | ehgraph `noetl-cluster` | What can *X* run, how is it reached, who may call it? | **the server projects it** from register calls plus the catalog | ehgraph version and `last_seen` |

**The member set.**

- Add `cli` and `daemon` to ehdb's `RuntimeKind` (an ehdb change), and to `parse_kind`.
- `cli` registers only when the CLI runs a long-lived listener (`noetl run … --listen`, or the
  proposed `noetl serve`). A one-shot `noetl run` never registers. Its record is the pushed
  history.
- A daemon registers on its subscription loop's timer, with the same idempotent upsert the
  workers use.

**The register body grows a capability block** (optional, so old members are unaffected):

```jsonc
POST /api/runtime/register
{
  "kind": "daemon",
  "id": "daemon:edge-mac:qnetmon-edge-mac",
  "contract": "noetl-cli/5.6.0",
  "capabilities": {
    "mode": "daemon",                       // cli | daemon | distributed
    "reach": "inbox",                       // push (has a reachable endpoint) | inbox (pull only)
    "endpoint": null,                       // https://… when reach=push
    "playbooks": ["qnetmon/playbooks/cycle"],  // what it can run (paths or globs)
    "subscriptions": ["qnetmon/subscribe/edge-mac"],
    "tool_kinds": ["shell","http","mcp","agent","python"],
    "credentials": ["unifi_cloud"],         // credential ALIASES it holds, never material
    "labels": {"site": "home", "arch": "arm64"}
  }
}
```

**The server projects this into ehgraph.** The server is the sole writer, so E2 holds. A member
never opens or writes the graph. That is the same rule `runtime_topology.rs` already states
for D8.

| Node type | id | Main props |
|---|---|---|
| `runtime` | `runtime:<id>` | `mode`, `reach`, `endpoint`, `contract`, `labels` |
| `playbook` | `playbook:<path>` | `version`, `exposed_mcp`, `exposed_agent`, `side_effecting` |
| `mcp_server` | `mcp:<path>` | `url`, `protocol`, `tools` (from the catalog `kind: Mcp`) |
| `subscription` | `subscription:<path>` | `source`, `mode` |
| `credential_alias` | `cred:<alias>` | (name only) |

Edges: `runtime -can_run-> playbook`, `runtime -hosts-> subscription`,
`runtime -holds-> cred`, `playbook -calls-> mcp_server | playbook`, and
`playbook -exposes_as-> mcp_server`.

- Each register call is a `graph.upsert` with `origin=runtime-registry`.
- A sweep `graph.deactivate {source: runtime-registry, not_seen_since: now - ttl}` retires
  members whose lease lapsed. This uses ehgraph's own soft-deactivate semantics.
- Catalog-derived nodes (`playbook`, `mcp_server`) are upserted on register and delete, with
  `origin=catalog`.

**Discovery API.**

- `GET /api/runtime/discover?playbook=<path>&mode=&label=` joins D8 liveness with ehgraph
  capability, and returns ranked candidates `{runtime_id, mode, reach, endpoint}`.
- Agents and AI models do not need a new API. They call ehgraph's existing MCP tools
  (`graph.query type=runtime`, `graph.neighbors`) through the catalog resource
  `mcp/ehgraph/noetl-cluster`.

**IaC tie-in.** This is the same projection writer the deployment-modes doc lists as missing
for IaC Phase 1 ("the ehgraph topology writer"). Provider facts add `resource` nodes and
`depends_on` / `owned_by` edges in the same graph. A runtime is just another resource, and a
daemon on a host is then reachable by graph path from the infrastructure that runs it.

### 2.2 The call envelope

Every cross-mode invocation, on-demand or subscription-triggered, is one `RemoteTask`:

```jsonc
{
  "task_id": "7342…",                  // server snowflake; the idempotency key for the hop
  "target": {"runtime_id": "daemon:edge-mac:…"}  // or {"selector": {"mode":"daemon","label":{"site":"home"}}}
  "playbook": {"path": "qnetmon/playbooks/cycle", "version": 12, "sha256": "…"},
  "payload": {"…": "…"},
  "caller": {"principal": "user:auth0|…", "via": "runtime:server", "execution_id": 7341, "step": "probe_edge"},
  "reply": {"mode": "callback",        // callback | poll | none
            "url": "https://…/api/callbacks/7342",
            "token": "<single-use, bound to task_id>"},
  "deadline_ms": 1762531200000,
  "trace": {"traceparent": "00-…"}
}
```

- **The playbook is sent by reference** (path, version, and content hash). The target fetches
  it from the catalog, or uses its local copy if the hash matches. A hash mismatch is a refusal.
  This closes the drift hole #452 describes: the target never runs content the caller did not
  name.
- **Payload values never carry secret material.** Credentials are aliases the target holds,
  per #455 `SecretRef`. Registration-time secret scanning (`catalog.rs` `secret_material::scan`)
  applies to payloads too.

### 2.3 Delivery: push or inbox

| Target `reach` | Delivery |
|---|---|
| `push` (cluster, or a LAN daemon with an endpoint) | `POST <endpoint>/api/tasks` with the envelope; returns `202 {task_id}` |
| `inbox` (edge daemon behind NAT, laptop) | the server enqueues to `inbox:<runtime_id>`; the member long-polls `GET /api/runtime/{id}/inbox?after=<cursor>` and acks |

The inbox is the important case. qnetmon's edge Mac runs a `KeepAlive` daemon and is not
addressable from the cluster. The daemon already runs a poll loop (`noetl subscribe`), so the
inbox is **a new subscription source, `source: noetl-inbox`**. The daemon's existing
header-directive, spool and dispatch machinery handles it unchanged. Server-side, the inbox is
an EHDB feed subject (`runtime.<id>.inbox`). The worker command bus already proves claim/ack
semantics on that feed.

### 2.4 Results: one generic callback

Generalise the container path (§1.4) into `POST /api/callbacks/{task_id}`:

- **Body:** `{state: completed|failed|cancelled, result | error, execution_ref}`, where
  `execution_ref` points at the remote run's own event log: an EHDB execution id, or a pushed
  Feather segment.
- **Auth:** the single-use `reply.token`. It is an HMAC over `(task_id, caller.execution_id, caller.step, deadline)`
  with a server key, so a leaked token can complete exactly one step, once, before its
  deadline.
- **Semantics** are copied from `container_callback.rs`: 202 on stale or duplicate callbacks,
  stale counters, and no 4xx for races.
- **In the caller's DAG**, the calling step's tool returns `pending_callback = true`, so the
  worker skips `call.done`. The callback emits `call.done` or `call.error` for
  `(execution_id, step)`.
  - This is exactly the container round-trip. The worker metric
    `noetl_worker_call_done_skipped_pending_callback_total` and its
    "skipped ≈ callbacks" health rule (`worker/src/metrics.rs:899-917`) carry over.
- **A daemon or CLI caller** that has no server receives the callback on its own endpoint, or
  polls `GET /api/tasks/{task_id}` (`reply.mode: poll`).

**Playbook surface.** This is a `playbook` step with a `runtime` target:

```yaml
- step: probe_edge
  tool:
    kind: playbook
    path: qnetmon/playbooks/cycle
    runtime: { selector: { mode: daemon, label: { site: home } } }   # new; absent = today's behaviour
    reply: callback
```

### 2.5 Subscriptions across modes

- `source: noetl-inbox` lets a daemon receive on-demand tasks (§2.3).
- `source: noetl-events` lets any mode subscribe to *another* mode's execution events, for
  example "when `iac/apply` completes in the cluster, run `qnetmon/refresh` on the edge
  daemon". Server-side, this is a filtered view of the event log, delivered through the same
  inbox, or through gateway SSE for browser and agent consumers.
- Add `timer` to `SUBSCRIPTION_SOURCES` (`catalog.rs:475`), so the same timer spec registers in
  the cluster as well as running as a daemon. The worker's subscription runtime already links
  the noetl-tools `TimerSource`.

### 2.6 The interop matrix

| Caller → target | Today | Proposed |
|---|---|---|
| CLI/daemon → cluster | `/api/execute`, `--dispatch server`, `noetl push` | plus `RemoteTask` with a callback to the caller |
| cluster → daemon | none | inbox, plus `noetl-inbox` source |
| daemon → daemon | none | via the server's inbox (broker), or push on a LAN |
| cluster → CLI | none | only for a CLI in `--listen` / `serve`; otherwise N/A |
| any → external MCP/agent | CLI only | `kind: mcp` / `kind: agent` everywhere (§3) |
| external MCP client/agent → any | none | server MCP endpoint; routed to a daemon via discovery plus inbox |

---

## 3. Thread 2: first-class, bidirectional AI/MCP

### 3.1 Outbound: `kind: mcp`

1. **The server accepts the kind** behind `NOETL_TOOL_KIND_MCP` (**Phase 1**). The `ToolSpec`
   flatten catch-all (`playbook.rs`, `extra: HashMap`) already carries `endpoint`, `server`,
   `method`, `tool` and `arguments` through to the worker unchanged. The worker's registry
   dispatches by kind string.
2. **`server: mcp/<path>` resolves against the catalog `kind: Mcp` resource** (`spec.url`).
   This removes the env-var-per-server convention, and makes the embedded graph callable by
   path. *(Phase 2, noetl/worker#397: resolved **on the worker at dispatch**, not at
   command-build time on the server. Commands are also built by the off-server orchestrate
   drive, and the worker is the one place every `mcp` command passes. Unregistered or
   non-`Mcp` resources fail the step terminally; a catalog outage retries.)*
3. **Authentication.** `auth:` resolves through the worker's existing credential path into an
   `Authorization` header, and `headers:` may carry `{{ keychain.<alias>.<field> }}` templates.
   *(Phase 2: done in the worker, not noetl-tools, because the worker is exact-pinned to
   tools `=4.0.1` (#330). A worker `mcp` tool sends the headers, and delegates unchanged to
   tools' `McpTool` when a step sets neither. The result names the headers sent
   (`sent_headers`), never their values.)*
4. **Per-step error policy.** `on_provider_error: fail | continue` per step overrides the
   global `NOETL_PROVIDER_ERROR_TERMINATES`, so `isError` handling is a decision the author
   makes. *(Phase 2: with `fail`, an `mcp` transport failure counts too.)*
5. **Long-running MCP calls.** If the server answers a `tools/call` with a task handle or
   progress token, McpTool returns `pending_callback` and the completion arrives through
   `/api/callbacks` (§2.4).

### 3.2 Outbound: `kind: agent`

The CLI already runs the agent loop turn by turn. `AgentSession` keeps the message history as
plain JSON, precisely "the shape a distributed, callback-driven runner would need"
(`tools/src/tools/agent.rs` module doc). In the cluster:

- **Stage A (tool-less agents).** Register `AgentTool` in the worker's registry behind a worker
  flag. Then enable `NOETL_TOOL_KIND_AGENT` on the server. The whole loop runs inside one
  command. A model that asks for a tool fails loudly, which is AgentTool's documented
  behaviour.
  - Blocked on the worker leaving `noetl-tools =4.0.1` (#330).
  - `framework: claude-code` stays CLI-only. It needs a signed-in local `claude` binary and
    must be refused in cluster pools.
- **Stage B (tools as playbooks and MCP).** The orchestrator drives the loop:
  - Each model turn is one command.
  - Each `tool_use` becomes a child step, either `kind: playbook` or `kind: mcp`, possibly
    remote (§2.4).
  - The next turn is issued when the children complete.
  - The conversation state is a step-scoped variable on the event log, so an agent run is
    replayable and auditable like any other execution.
  - Budgets (`max_turns`, `max_tokens`) are enforced by the orchestrator, not trusted to the
    model.
- **Stage C (external agents).** `framework: remote` (an A2A-style or MCP-fronted agent
  endpoint). Send the task, return `pending_callback`, and complete through `/api/callbacks`.

### 3.3 Inbound: a playbook exposed as an MCP tool, and an MCP server built from playbooks

**Opt-in exposure metadata.** The default is not exposed.

```yaml
metadata:
  path: qnetmon/playbooks/cycle
  expose:
    mcp:
      tool: qnetmon_cycle            # MCP tool name (default: path with / → _)
      description: Run one network monitoring cycle.
      input_schema: {type: object, properties: {site: {type: string}}}   # default: derived from workload
      mode: async                    # sync (wait ≤ timeout) | async (return a handle)
    agent:
      card: {name: qnetmon, skills: [network-monitoring]}
```

**A server MCP endpoint, `POST /api/mcp`, proxied by the gateway as `/noetl/mcp`.** Its shape
mirrors ehgraph's surface (`initialize`, `ping`, `tools/list`, `tools/call`; result
`{content:[…], isError}`):

- `tools/list` returns the exposed playbooks the **caller is allowed to execute**. Gateway
  authorization (`may_execute`, `gateway/src/authorization.rs`) is the filter, so enumeration
  never leaks paths a user cannot run.
- `tools/call` maps to `/api/execute`, with `trace` carrying the MCP request id.
  - `sync` waits up to the step timeout and returns the result.
  - `async` returns `{execution_id}` immediately.
  - Progress and completion are pushed as MCP notifications over the streamable-HTTP response
    (SSE). The gateway already serves SSE.
  - A `callback_url` argument is also accepted for webhook-style clients.
- Fixed helper tools: `noetl.execution.status`, `noetl.execution.result` and
  `noetl.execution.cancel`, so clients that cannot hold a stream still get completion.
- An `isError` result reflects a failed execution, and `content` links the execution id for
  audit.

**"An MCP server as a NoETL playbook" means a `kind: Mcp` resource whose tools are bound to
playbooks.** It is served at `/api/mcp/{resource_path}`:

```yaml
apiVersion: noetl.io/v2
kind: Mcp
metadata: { name: qnetmon, path: mcp/qnetmon }
spec:
  serve: true
  tools:
    - { name: cycle,   playbook: qnetmon/playbooks/cycle }
    - { name: devices, playbook: qnetmon/playbooks/devices, mode: sync }
```

The same resource type is used for *consuming* MCP servers today (§1.3). Adding `serve: true`
makes NoETL the server. It is registered in ehgraph as an `mcp_server` node with
`playbook -exposes_as->` edges, so discovery is symmetric.

**"An AI agent as a NoETL playbook" is a playbook whose body is a `kind: agent` step, with
`expose.agent` set.** It is served as an agent card (`GET /api/agents/{path}/card`), and invoked
through the same MCP `tools/call` or an A2A-style `tasks/send`. Both map to `/api/execute`, with
callbacks as above.

**Where it runs.** On `tools/call`, the server consults discovery (§2.1). If the exposed
playbook's only capable runtime is a daemon, the call becomes a `RemoteTask` to its inbox. An
external MCP client can therefore reach an edge box without that box being exposed to the
internet.

### 3.4 AI coordinating execution

The coordinator is a playbook, not a new subsystem:

```yaml
- step: plan_and_dispatch
  tool:
    kind: agent
    framework: claude
    model: claude-sonnet-5-5
    prompt: "Run a network health sweep on every site that is up; summarise anomalies."
    tools:
      - { name: topology, mcp: mcp/ehgraph/noetl-cluster, tool: graph.query }   # who is up, what they run
      - { name: dispatch, playbook: system/dispatch }                            # RemoteTask to a selector
      - { name: result,   playbook: system/task_result }
```

**Guardrails:**

- Tool allowlists per agent step.
- `kind_is_side_effecting` (noetl-tools registry) marks dispatches of side-effecting playbooks
  as requiring an approval gate, which is a human-in-the-loop step.
- Orchestrator-enforced turn and token budgets.
- Every model turn and every dispatched task is an event, so "what did the AI do and why" is a
  query on the event log, not a log scrape.

---

## 4. Security, identity and auth

| Concern | Design |
|---|---|
| Member identity | In-cluster members: the internal API token or workload identity, behind the #303 gate (shadow → enforce). Daemon/CLI: a one-time **enrollment token** exchanged at `POST /api/runtime/enroll` for a short-lived runtime JWT (`sub=runtime:<id>`, `aud=noetl-runtime`, scopes `register`, `inbox:read`, `run:<path-glob>`), renewed with the lease. |
| Per-call identity | `caller.principal` is the end user or agent principal, propagated across hops (`on_behalf_of`). The **target re-authorizes**: the server checks `may_execute(principal, playbook)` before enqueueing, and the target refuses playbooks outside its `run:` scope. Authority never widens across a hop. |
| Callbacks | A single-use HMAC token bound to `(task_id, execution_id, step, deadline)` (§2.4). Never reusable, never a general credential. |
| Inbound MCP / agent | Gateway auth (Auth0 session or API token) is required. `tools/list` is filtered by `may_execute`. Exposure is **opt-in** per playbook (`metadata.expose`). |
| Outbound MCP / agent | Credentials by alias only (`auth.credential`). `framework: claude` has no ambient key (AgentTool already requires `auth`). `claude-code` is refused in cluster pools. |
| Secrets | Envelopes, payloads, `contract` and capability blocks never hold material (#455 `SecretRef`). `capabilities.credentials` lists aliases, never values. |
| Prompt injection | Tool and MCP results are data to the agent loop. Side-effecting dispatches need an approval step. Tool allowlists are per step. Budgets are enforced by the orchestrator. |
| Enumeration | Discovery and topology stay behind the #303 gate (as `runtime_topology_routes` is today), and ehgraph keeps its own per-namespace grants. |
| Audit | Every hop is an execution with events. Every remote run links back through `caller.execution_id`, and its own history arrives through `noetl push` or the cluster event log. |

---

## 5. Mapping to existing work

- **Deployment modes doc.** This RFC adds the missing downward and sideways arrows (inbox,
  callbacks), plus two registry kinds (`cli`, `daemon`). "Moving up is additive" stays true. A
  daemon that never enrolls behaves exactly as today.
- **NoETL-as-IaC (ops ADR-0001…0007).**
  - The topology projection writer (§2.1) is the "ehgraph topology writer" that IaC Phase 1
    needs.
  - Provider facts become `resource` nodes in the same `noetl-cluster` graph, so runtimes and
    infrastructure share one topology.
  - Phase 0 Feather histories from CLI runs keep arriving through `noetl push` and are linked
    by `execution_ref`.
- **ehgraph.**
  - No engine changes are needed for Thread 1: node and edge types, soft-deactivate,
    `not_seen_since` sweeps, MCP tools and grants all exist.
  - The server stays the single writer (E2).
  - The `noetl-cluster` graph becomes the AI's map of the platform, through its MCP surface.
- **#447.** Phase 1 makes `mcp` and `agent` valid in **both** namespaces when their flags are
  on. The two-namespace distinction still holds, and the ADR records it.

---

## 6. Phased plan

Each phase is independently shippable and flag-gated OFF, and none arms prod.

| Phase | Slice | Repo(s) | Flag(s) | Tests |
|---|---|---|---|---|
| **1** *(noetl/server#560)* | Server `ToolKind` gains `Mcp` and `Agent`. They are **gated at deserialization**, so registration *and* execute behave exactly as today when off. | server | `NOETL_TOOL_KIND_MCP`, `NOETL_TOOL_KIND_AGENT` (both off) | Off: rejected at registration with the #256 message, and execute-parse fails. On: accepted, round-trips, list form plus nested. `valid_set` hides gated kinds. Flags are independent. |
| **2** *(noetl/worker#397, noetl/server#561, noetl/ops#364)* | `kind: mcp` end to end in kind: a playbook upserts into and reads back from the embedded ehgraph through `kind: mcp` (dogfood). `Authorization` from a keychain alias or header template; `server: mcp/<path>` resolution; per-step `on_provider_error`. | worker, server, ops | none new: inert unless a step uses it; `NOETL_TOOL_KIND_MCP` armed in kind only | kind e2e 23/23: authenticated roundtrip COMPLETED with results on the event log; unauthenticated + `fail` → FAILED |
| 3 | Topology: `cli`/`daemon` `RuntimeKind`; register `capabilities`; server → ehgraph projection writer plus a TTL sweep; `GET /api/runtime/discover`; `noetl subscribe --register <server>` heartbeat. | ehdb, server, cli | `NOETL_EHGRAPH_TOPOLOGY_WRITER`, CLI `--register` | projection idempotency (same upsert, no version bump), lapse → deactivated, discover join |
| 4 | `RemoteTask` plus `/api/callbacks` (generalising container-callback) plus an inbox feed subject plus the `noetl-inbox` source; `kind: playbook` `runtime:` target; enrollment JWT. | server, cli, tools | `NOETL_REMOTE_TASKS` | stale/duplicate callback → 202; a token completes one step once; inbox claim/ack/redelivery |
| 5 | Server MCP endpoint `/api/mcp` plus gateway proxy; `metadata.expose`; `kind: Mcp` `serve: true`; status/result/cancel helpers. | server, gateway | `NOETL_MCP_SERVER` | `tools/list` filtered by `may_execute`; sync/async; SSE completion |
| 6 | `kind: agent` in the cluster. Stage A: worker registers `AgentTool` after the #330 unpin, then flip `NOETL_TOOL_KIND_AGENT` in kind. Stage B: orchestrator-driven turns with playbook/MCP tools. Stage C: remote agents. Agent cards. Coordinator playbook. | tools, worker, server | `NOETL_WORKER_AGENT_TOOL`, server flag | replay of an agent run; budget enforcement; approval gate |

**Why Phase 1 is the smallest safe slice.**

- It is a server-only change.
- It changes behaviour only if an operator sets an env var.
- With the flags off, the execute-time deserialization rejects `mcp` and `agent` exactly as
  today, so the old `kind: mcp` / `kind: agent` catalog rows #256 found **do not silently become
  executable**.
- It unblocks Phase 2's kind e2e, because only `NOETL_TOOL_KIND_MCP` is needed: the worker
  already has `McpTool`.

**Phase 2 result (2026-11-08).** The kind e2e passes 23/23 (`ops ci/kind/e2e_mcp_ehgraph.sh`).
- The server and worker run `kind: mcp` against the embedded ehgraph `noetl-cluster` MCP endpoint:
  - the endpoint is found through the catalog;
  - the call authenticates with a keychain bearer;
  - the token never reaches the event log.
- It surfaced a Phase 1 gap, fixed in noetl/server#561. The off-server wasm drive has no environment, so
  its tool-kind gates read closed, and it refused the `mcp` steps the server had admitted. Admission stays
  gated where a playbook enters: registration and the server's execute-time parse.
- One open observation: in 1 of 6 runs, the first execution after a rollout looped on its `noop` `start`
  step. See the ops BUILD_LOG.

**Do not turn on `NOETL_TOOL_KIND_AGENT` until Phase 6 Stage A ships a worker that registers
`AgentTool`.** Turning it on earlier reintroduces exactly the #256 failure, a kind that
registers but cannot execute. The ADR records this.

---

## 7. Open questions

1. Inbox transport: an EHDB feed subject per runtime (proposed), or one shared subject filtered
   by `target`? Per-runtime subjects bound blast radius, but grow the subject count.
2. Should `cli --listen` exist at all, or is "a CLI that can be called" just a daemon with
   `--once`?
3. MCP spec alignment for long-running tool calls. Track the MCP "tasks" work. Until then, use
   progress notifications plus helper tools.
4. A2A versus MCP-only for agent exposure. The proposal: MCP first, and the agent card is
   metadata.
5. Whether `metadata.expose.mcp.input_schema` should be derived from `workload` automatically,
   or always authored explicitly (safer).
