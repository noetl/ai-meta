# Build plan: the missing interop, MCP and agent tools

Companion to [`interop-topology-and-ai-mcp-playbooks.md`](interop-topology-and-ai-mcp-playbooks.md)
(the RFC, ai-meta#539). The gap list comes from qnetmon's
`docs/demo/mcp-and-agents.md` and `docs/demo/runtimes-and-interop.md` (checked 2026-11-09
against `origin/main` of cli `3d8c501`, server `5cf0712d`, worker `ddc9eb9`, tools `89302cc`,
gateway `1cb355a`). This page orders that list by dependency and risk.

Rules for every item: one feature per branch and PR, flag-gated OFF where it touches the
cluster, tested locally (unit, local runtime, kind). No item flips a prod flag, changes a prod
manifest or touches the qnetmon demo. qnetmon runs a vendored `.bin/noetl` 5.4.0, so no CLI
change reaches the edge daemon until someone upgrades that binary on purpose.

## The order

| # | Item | Repo(s) | Depends on | Risk | Flag |
|---|---|---|---|---|---|
| **1** | **`kind: playbook` returns its result to the parent on the local runtime** (`return_result` / `result_step`, same fields as the cluster) | cli (+ noetl-executor) | — | Low: opt-in field, default unchanged | none (opt-in field) |
| 2 | Local runtime **rejects** unsupported kinds (`kind: mcp` today) at load time instead of skipping the step and exiting `ok` | cli | — | Low, but behaviour-visible: a playbook that "passed" by skipping now fails | none |
| 3 | `kind: mcp` **on the local runtime**, via noetl-tools `McpTool` (endpoint / `NOETL_MCP_*` env, `auth:` from the local credential store, `on_provider_error`) | cli | 2 | Low–medium: new kind, no change to existing kinds | none |
| 4 | Worker **unpin** from `noetl-tools =4.0.1` and register `AgentTool` behind `NOETL_WORKER_AGENT_TOOL` (RFC Phase 6 Stage A); refuse `framework: claude-code` in pools | worker (tools) | ai-meta#330 unpin | Medium: dependency bump on the worker; kind e2e needed | `NOETL_WORKER_AGENT_TOOL` (worker), then `NOETL_TOOL_KIND_AGENT` in **kind only** |
| 5 | **Inbound MCP for playbooks**: server `POST /api/mcp` (`initialize`, `ping`, `tools/list`, `tools/call`), `metadata.expose.mcp`, `kind: Mcp` `serve: true`, gateway proxy `/noetl/mcp` with `tools/list` filtered by `may_execute` (RFC Phase 5) | server, gateway | 1 (sync result semantics), catalog | Medium: new public surface; off by default | `NOETL_MCP_SERVER` |
| 6 | **External agents / MCP from `kind: agent`**: `framework: remote` (A2A-style or MCP-fronted) plus `mcp_servers:` tool sources, so a model's tool can be an MCP tool and not only a playbook (RFC Phase 6 Stage C) | tools, cli, worker | 3, 4; callbacks (7) for async | Medium | per-framework, off on cluster |
| 7 | **Playbook-as-agent**: generic `/api/callbacks` with single-use HMAC tokens (Phase 4, generalising container-callback), agent cards (`GET /api/agents/{path}/card`), `tasks/send` → `/api/execute` | server, gateway | 5 | Medium–high: new auth surface | `NOETL_REMOTE_TASKS`, agent flag |
| 8 | **Agents/MCP on KEDA shared pools with a per-turn EHDB record**: orchestrator-driven turns, each `tool_use` a child step, conversation state as a step-scoped variable (Phase 6 Stage B) | server, worker, tools | 4, 6 | High: orchestrator change | server flag |
| 9 | **Cross-runtime discovery**: `cli`/`daemon` `RuntimeKind`, edge identity, `noetl subscribe --register`, `GET /api/runtime/discover`, inbox pull (`RemoteTask`), topology push to `noetl-cluster` (RFC Phases 3–4) | ehdb, server, cli, gateway | 7 (callbacks / inbox) | High: identity + new ingress | `NOETL_EHGRAPH_TOPOLOGY_WRITER`, `NOETL_REMOTE_TASKS`, CLI `--register` |

Items 1–3 are CLI-only and cleanly independent of 4. Item 4 can run in parallel with 1–3.

## Why item 1 first

- **Foundational.** Every inbound pattern in the RFC (an MCP `tools/call`, an agent `tasks/send`,
  a dispatcher playbook) is "a playbook calls a tool playbook and returns what it got". Today
  the local runtime can't do that: `Tool::Playbook` ends in `Ok(None)` (cli
  `src/playbook_runner.rs`). qnetmon's `mcp_shaped_dispatch.yaml` has to inline its tool for this
  reason. The agent loop is the only local path that reads a child's result.
- **Lowest risk.** The cluster already has the shape: noetl-tools `PlaybookConfig.return_result`
  and `result_step` (ai-meta#136), opt-in, default off. Adding the same two fields to the local
  executor changes nothing for existing playbooks, and makes one playbook portable across
  runtimes. No server, worker, flag or prod change.
- **Highest leverage per line.** ~50 lines plus tests unblock MCP-shaped dispatchers on the edge
  now, and give item 5's sync `tools/call` a tested local reference for "the result of a playbook".

## Decisions that need an owner

- **Item 2 is behaviour-visible.** `noetl run` on a playbook with an unsupported kind will exit
  non-zero instead of `ok`. Proposed: error by default, with the message naming the step and the
  runtime that does support it. No flag to keep the silent skip.
- **Item 4 needs ai-meta#330 closed** (the noetl-tools 4.x unpin on the worker). Worker images
  are built from `main`; the PR stays unmerged until the kind e2e is green and an owner schedules
  the rollout.
- **Item 5 API shape.** RFC §3.3 proposes `/api/mcp` and `/api/mcp/{resource_path}`. Open
  question 5 (derive `input_schema` from `workload` or require it authored) should be settled
  before the PR: the plan assumes **authored only**, as the safer default.
- **Item 5 / 7 schema source:** settled. The owner left it to us: hand-written, never derived from `workload`, and it can be revisited.
- **Item 1 default.** `return_result` stays opt-in for parity with the cluster. A later DSL major
  could make "return the child's result" the default on both runtimes together.

## Status

| # | Branch / PR | State |
|---|---|---|
| 1 | cli `feat/local-playbook-result`, noetl/cli#103 | PR open, tests green, unmerged |
| 5 | server `feat/mcp-server-playbooks` (noetl/server#564), gateway `feat/mcp-proxy-may-execute` (noetl/gateway#65) | PRs open, unit/integration green, kind e2e pending; flags `NOETL_MCP_SERVER` / `GATEWAY_MCP_PROXY` off |
| 2 | cli `feat/local-reject-unsupported-kinds` (noetl/cli#104) | approved by the owner (no opt-out); PR open, tests green; `feat!` → semantic-release cuts noetl 6.0.0 on merge |
| 4 | — | blocked on #330 |
| 7 | server `feat/agent-endpoint-callbacks` (noetl/server#565, stacked on #564) | PR open, tests green, kind e2e pending; flag `NOETL_AGENT_ENDPOINT` off, callbacks need `NOETL_AGENT_CALLBACK_ORIGINS`. Durable `/api/callbacks` (Phase 4) and a gateway `/noetl/agents` route are follow-ups |
| 3, 6, 8, 9 | — | not started |
