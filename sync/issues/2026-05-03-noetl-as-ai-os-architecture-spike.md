# NoETL as AI OS — playbook ≡ agent ≡ MCP server (architecture spike)

**Status**: design / not yet building
**Repos affected**: `noetl/noetl`, `noetl/ops`, `noetl/gui`,
  `noetl/docs`
**Date**: 2026-05-03

A focused spike to close the gap between today's catalog-driven MCP
architecture (Phases 1-4 — see
`memory/inbox/2026/04/20260429-060000-mcp-architecture-end-to-end-running.md`)
and the broader claim in
[`docs/ai-meta/agent-orchestration.md`](https://noetl.dev/docs/ai-meta/agent-orchestration):
**a NoETL playbook is, simultaneously, an agent definition and a
candidate MCP server**.

The architecture today realises half the claim. This spike sketches
what it takes to realise the other half.

---

## What we have today (rapid recap)

| Capability | State | Where |
|---|---|---|
| `kind: Mcp` resource in the catalog | ✓ | `noetl#392`, `noetl#395` |
| Server-side `check_playbook_access` | ✓ | `noetl#394` |
| Lifecycle agent fleet (deploy/undeploy/…) | ✓ | `ops#15..18` |
| Friendly run dialog + Mcp tile renderer | ✓ | `gui#16..19` |
| `tool: shell` distributed | ✓ | `noetl#400` |
| `tool: mcp` (JSON-RPC client to external MCP server) | ✓ | pre-existing in `noetl/tools/mcp/` |
| `tool: agent` (Python entrypoint adapter for ADK / LangChain / custom callables) | ✓ | pre-existing in `noetl/tools/agent/` |
| `metadata.agent: true` + `capabilities[]` on playbooks | ✓ | spec'd in `agent-orchestration.md`; honored by catalog |
| **NoETL playbook invokable AS an agent** (without Python glue) | ✗ | gap — `tool: agent` only calls external Python |
| **NoETL playbook served AS an MCP server** to external clients | ✗ | gap — no inbound `tools/list` / `tools/call` translator |
| **Self-troubleshooting playbooks** for runtime introspection | ✗ | gap — no playbooks under `automation/troubleshoot/` |
| **Local LLM as a `kind: Mcp` resource** for cheap-first inference | ✗ | gap — no Ollama / llama.cpp registered |

---

## Concept — playbook ≡ agent ≡ MCP server

The framing the agent-orchestration doc commits to:

> A playbook is an agent definition. The catalog is the registry.
> NATS is the IPC. Workers are the runtime. Events are the audit
> trail.

Three roles every NoETL playbook can satisfy depending on how it's
invoked:

| Role | How a caller invokes it | What the caller passes | What the caller gets |
|---|---|---|---|
| **Playbook** | `POST /api/execute` (or `noetl run`) | full workload | `execution_id`, then events |
| **Agent** | `tool: agent` with `framework: noetl, entrypoint: <playbook path>` | turn-based prompts / context | structured response, optionally streamed |
| **MCP server** | `POST /api/mcp/playbooks/<path>/tools/list` then `tools/call/<tool>` | JSON-RPC `tools/call` envelope | JSON-RPC result, framed as MCP response |

The same YAML file. Three different entry points. The catalog row
is the registry; the worker dispatches; events flow into the same
tables.

For this to work we need to fill three holes:

1. **`tool: agent` framework=`noetl`** — call a peer playbook as an
   agent (turn loop semantics, context passing) without a Python
   entrypoint shim.
2. **MCP-server-as-playbook endpoint** — an HTTP surface on the
   noetl server that translates MCP JSON-RPC into playbook
   executions.
3. **A small, declarative way for a playbook to say "I expose
   myself as MCP"** — minimal metadata so `tools/list` can return
   accurate schemas.

---

## Gap 1 — `tool: agent` framework=`noetl`

Today's `tool: agent` (in `noetl/tools/agent/executor.py`) loads a
Python entrypoint via `framework: adk | langchain | custom`,
factory-or-callable mode, with `entrypoint_args` etc. It's an
adapter for external libraries.

What's missing: `framework: noetl` that treats the entrypoint as a
peer playbook path:

```yaml
- step: ask_local_model
  tool:
    kind: agent
    framework: noetl
    entrypoint: agents/local_llm/gemma_chat   # peer playbook path
    payload:
      prompt: "{{ workload.user_query }}"
      max_turns: 4
    # optional — match the existing adapter's shape
    invoke_kwargs:
      temperature: 0.2
```

Inside the executor, this branches to a code path that:

- Resolves the entrypoint as a catalog playbook path
- Dispatches it as a sub-playbook (existing `tool: kind: playbook`
  machinery) with the agent's `payload` as `workload.input`
- Awaits completion (using `return_step` semantics already in the
  playbook tool — see redeploy.yaml)
- Returns `result.text` / `result.data` shaped like the other
  agent adapters

Cost: ~80 lines in the agent executor + a test fixture. Doesn't
need new noetl-server endpoints — the dispatch primitive already
exists.

---

## Gap 2 — MCP-server-as-playbook endpoint

Today, `tool: mcp` calls **external** MCP servers (JSON-RPC over
HTTP). The reverse — letting an external MCP client call a NoETL
playbook as if it were an MCP server — doesn't exist.

A minimal addition to noetl's FastAPI app:

### Routes

```
GET  /api/mcp/playbooks/{path}/info
       -> { name, version, capabilities[], description }

POST /api/mcp/playbooks/{path}/tools/list
       -> { jsonrpc, result: { tools: [{name, description, inputSchema}] } }

POST /api/mcp/playbooks/{path}/tools/call
       Body: { jsonrpc, method: "tools/call", params: { name, arguments } }
       -> { jsonrpc, result: { content: [{type, text}] } }
            (or streams via SSE for long-running tool calls)
```

### Implementation sketch

`/tools/list` reads the playbook's `metadata.exposes_as_mcp.tools`
(see Gap 3). For each declared tool, returns the JSON Schema of the
tool's input — derived either from the `workload:` block or from an
explicit `inputSchema:` on the tool declaration.

`/tools/call` translates the call envelope into a playbook
execution: the named tool corresponds to a sub-playbook path or a
named entry-point step within the same playbook. Workload is the
JSON-RPC `params.arguments`. Wait for completion, project the
result into the MCP `content` shape.

### Authorization

Same `check_playbook_access` enforcement (Phase 2) gates these
routes — granting `execute` on the playbook path is granting MCP
client access. The MCP `tools/list` is gated by `view`.

### Discovery

External MCP clients today use a config file pointing at server
URLs. Eventually we'd want a discovery shape like:

```
GET  /api/mcp/registry
       -> [
            { name: "noetl/troubleshoot", url: "/api/mcp/playbooks/automation/troubleshoot/analyze" },
            { name: "noetl/k8s-runtime",   url: "/api/mcp/mcp/kubernetes" }   ← existing Mcp resource
          ]
```

…so a single noetl deployment exposes both first-party MCP
resources (existing `kind: Mcp` rows) AND playbook-backed MCP
servers (new) under one registry endpoint.

Cost: ~300-400 lines in `noetl/server/api/mcp/playbook_endpoint.py`,
plus tests. Adds one new endpoint module, no new dependencies.

---

## Gap 3 — declarative MCP exposure on a playbook

A playbook opts in to MCP-server-ness via metadata:

```yaml
apiVersion: noetl.io/v2
kind: Playbook
metadata:
  name: noetl_self_troubleshoot
  path: automation/troubleshoot/analyze
  agent: true
  capabilities: [troubleshooting, analyze, llm-summary]
  exposes_as_mcp:
    tools:
      - name: analyze_execution
        description: |
          Analyse a NoETL execution by id, summarise events,
          and return a structured diagnosis.
        inputSchema:
          type: object
          required: [execution_id]
          properties:
            execution_id: { type: string }
            include_logs: { type: boolean, default: true }
        playbook_step: analyze   # which top-level step is "the tool"
      - name: summarise_failures_today
        description: |
          Top-N failed steps in the last 24h, summarised by a local model.
        inputSchema:
          type: object
          properties:
            top_n: { type: integer, default: 10 }
        playbook_step: summarise_failures
```

The `_ui_schema` endpoint (Phase 1) already infers a JSON schema
from `workload:`. The `exposes_as_mcp.tools[*].inputSchema` is the
explicit version of the same idea, scoped per-tool rather than per-
playbook.

Validation: extend the v10 Pydantic model with an optional
`metadata.exposes_as_mcp` block. Register-time validation (#397)
catches typos.

---

## Gap 4 — self-troubleshooting playbooks (the workstream that
                              motivated the spike)

Three layered playbooks under `repos/ops/automation/troubleshoot/`:

### `analyze_execution.yaml`

Inputs: `execution_id`, optional `include_logs: bool`.

Workflow:

1. `tool: postgres` — read `noetl.event` for that execution, sample
   N events, count by `event_type`.
2. `tool: postgres` — read `noetl.command` for that execution,
   identify failed commands.
3. `tool: shell` (in-cluster) — `kubectl logs -l app=noetl-worker
   --tail=200 | grep <execution_id>`.
4. `tool: agent` framework=`noetl`, entrypoint=`agents/local_llm/gemma_summarise`,
   payload = the joined event/command/log snapshot.
5. `tool: python` end step — assemble structured diagnosis.

Returns `{ status, summary, suspect_steps, suggested_actions, raw }`.

### `summarise_failures.yaml`

Inputs: `since_hours: int = 24`, `top_n: int = 10`.

Walks `noetl.execution` for failed runs in the window, groups by
playbook path + failed_step, summarises via local model. Same
`tool: agent` framework=`noetl` pattern.

### `escalate.yaml`

Inputs: a diagnosis from the previous two + a confidence threshold.
If the local model's confidence is below threshold, calls a remote
MCP server (e.g. an Anthropic-hosted MCP fronting Claude) via
`tool: mcp` against an `mcp/anthropic` catalog resource. Returns
the bigger model's analysis.

These three playbooks together with their `exposes_as_mcp` blocks
become a "noetl self-troubleshooting" MCP server that any external
MCP client (Claude Desktop, an IDE, another noetl playbook) can
talk to.

---

## Gap 5 — local LLM as a `kind: Mcp` resource

The `agent: noetl` framework calls a peer playbook called
something like `agents/local_llm/gemma_chat`. That playbook
internally uses `tool: mcp` against an `mcp/ollama` catalog
resource, which routes JSON-RPC `tools/call` to a local Ollama
server. The lifecycle agent fleet for `mcp/ollama` deploys Ollama
into the cluster and registers the served models (gemma:4b,
qwen3:6b, llama3:8b) as the MCP `tools` list.

Same shape as `mcp/kubernetes` today:

```yaml
apiVersion: noetl.io/v2
kind: Mcp
metadata:
  name: ollama
  path: mcp/ollama
spec:
  url: http://ollama.ollama.svc.cluster.local:11434/mcp
  protocol: mcp/1.0
  lifecycle:
    deploy:    automation/agents/ollama/lifecycle/deploy
    discover:  automation/agents/ollama/lifecycle/discover
    ...
  runtime:
    agent: automation/agents/ollama/runtime
  deployment:
    namespace: ollama
    chart_ref: oci://ghcr.io/ollama/charts/ollama
    image_tag: 0.4.x
    models: ["gemma:4b", "qwen3:6b"]
```

The cluster RBAC piece is already solved by
`noetl-worker-lifecycle-installer` (`noetl#401`).

---

## Composition — what the user actually types

After all five gaps close:

```
$ noetl prompt
noetl@kind:/$ fix 615525185935900941
   started automation/troubleshoot/analyze :: execution=619...
   ...
   summary: step `pods_list` failed in execution 615... — RBAC missing for
            mcp ServiceAccount; suggest manual ClusterRoleBinding apply
   suggested_actions:
     - kubectl apply -f docs/operations/mcp-end-to-end-local-kind.md (step 8)
     - reach out to ops if not authorised to apply cluster RBAC
   confidence: 0.84  (local gemma:4b)

noetl@kind:/$ fix 619... --escalate
   started automation/troubleshoot/escalate :: execution=620...
   ...
   summary (Claude via mcp/anthropic): … deeper analysis …
   confidence: 0.96
```

And from outside NoETL, an MCP client (Claude Desktop, Cursor)
points at `https://noetl.local/api/mcp/playbooks/automation/troubleshoot/analyze`
and the playbook fleet shows up as a tool group that can be
invoked from inside any LLM session.

---

## Why this matters (the "AI OS" claim)

A distributed OS makes many networked nodes look like one machine.
NoETL's claim is to do the same for **AI agents and tools**:
playbooks are programs, the catalog is the file system, NATS is the
IPC, workers are the kernel, events are the audit trail.

Today: NoETL hosts AI work that calls external agents and external
MCP servers. The catalog is the registry, the events are the audit
trail, the worker is the kernel. ✓

After this spike: NoETL's own playbooks BECOME the agents and the
MCP servers other systems use. The `tool: agent` and `tool: mcp`
boundaries are bidirectional. A NoETL deployment is reachable as
an MCP server from outside (Cursor, Claude Desktop, peer NoETL
deployments) AND can compose external MCP servers from inside
(via `mcp/anthropic`, `mcp/ollama`, `mcp/kubernetes`).

The result is one consistent execution model whether the work
originates from a CLI, a GUI button, a cron, an external MCP
client, or a peer agent — all routed through the same playbook
catalog.

---

## Implementation order (proposed)

| # | Work | Repo | Dep on | Size |
|---|---|---|---|---|
| 1 | `tool: agent` `framework: noetl` (Gap 1) | noetl | nothing | ~80 LOC + tests |
| 2 | `metadata.exposes_as_mcp` Pydantic field (Gap 3) | noetl | nothing | ~30 LOC + schema regen |
| 3 | `mcp/ollama` catalog template + lifecycle agents (Gap 5) | ops | nothing | follow the kubernetes-mcp-server template |
| 4 | self-troubleshooting playbooks (Gap 4) | ops | 1, 3 | three playbooks, ~400 LOC YAML |
| 5 | MCP-server-as-playbook endpoint (Gap 2) | noetl | 2 | ~400 LOC + tests + auth wiring |
| 6 | `/api/mcp/registry` discovery endpoint | noetl | 5 | ~50 LOC |
| 7 | docs page on noetl.dev — "NoETL as AI OS" | docs | 5 | ~500 lines markdown |

Order rationale: 1 + 3 unlock 4 (the self-troubleshooting workstream
the user actually asked for). 2 + 5 unlock the inbound-MCP claim.
6 + 7 close the "external clients can find this" loop.

Each work item is independently shippable as a PR. The whole arc is
2-4 weeks at this PR cadence.

---

## Open questions

1. **Streaming vs request/response**. MCP `tools/call` supports
   server-sent progress notifications. Playbook executions emit
   progress events to NATS already; we'd need to bridge those into
   the MCP response stream. SSE on
   `/api/mcp/playbooks/{path}/tools/call` is the natural shape but
   adds protocol complexity. Could ship request/response first and
   add streaming later.
2. **Authentication for inbound MCP**. The check_playbook_access
   flow expects a NoETL session token. MCP clients in the wild use
   per-connection bearer tokens, OAuth flows, etc. Probably need a
   small adapter that translates inbound MCP auth into NoETL
   sessions, OR an explicit "MCP client API key" abstraction.
3. **How does `mcp/registry` advertise the playbook-backed servers
   without duplicating the catalog?** Probably enumerate playbooks
   with `metadata.exposes_as_mcp` set and synthesise the entries.
   Adds a catalog query at registry-fetch time but no extra
   storage.
4. **Should `tool: agent framework=noetl` be a separate executor
   (`tool: subplaybook` already exists) or extend the existing
   agent executor?** Argument for extension: keeps the agent-
   orchestration mental model uniform. Argument for separate:
   cleaner separation of concerns. Lean toward extension because
   the doc already says "playbook IS an agent."

---

## Cross-references

- `repos/docs/docs/ai-meta/agent-orchestration.md` — public framing
- `repos/docs/docs/architecture/mcp_catalog_architecture.md` —
  what we shipped 2026-04-29
- `memory/inbox/2026/04/20260429-060000-mcp-architecture-end-to-end-running.md` —
  end-to-end milestone
- `sync/issues/2026-04-29-mcp-architecture-backlog.md` — six
  follow-ups; #51 (Mcp tab + Add-MCP wizard) overlaps with this
  spike's discovery story (Gap 6)
- `repos/noetl/noetl/tools/agent/executor.py` — current agent
  adapter (Python entrypoints)
- `repos/noetl/noetl/tools/mcp/executor.py` — current MCP client
  (calls external MCP servers)

Tags: architecture,spike,mcp,agent,ai-os,playbook,self-troubleshooting,backlog
