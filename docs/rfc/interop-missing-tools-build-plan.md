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
| 1 | noetl/cli#103 | merged 2026-11-10 (cli 5.6.0) |
| 5 | noetl/server#564, noetl/gateway#65 | merged 2026-11-10 (server 3.154.0, gateway 3.21.0); kind e2e green (noetl/ops#365); prod: `NOETL_MCP_SERVER` ON since 2026-11-10 (inert until a playbook opts in), `GATEWAY_MCP_PROXY` off |
| 2 | noetl/cli#104 | merged 2026-11-10 → **noetl 6.0.0** (crate, tarballs, deb/apt, brew all published) |
| 3 | noetl/cli#107 (+ noetl/tools#118) | **in PR**: `kind: mcp` on the local runtime and daemon through noetl-tools `McpTool` (auth alias from the local store, `on_provider_error`); catalog `server: mcp/<path>` still refused locally. Unit + local e2e 25/25 |
| 4 | noetl/worker#398 (+ noetl/tools#118) | **in PR**: #330's worker hold lifted (`noetl-tools =4.5.0`, async-nats 0.47, executor 0.14; no worker code change needed); `AgentTool::for_shared_pool()` behind `NOETL_WORKER_AGENT_TOOL` (claude-code refused); `WorkerMcpTool` delegates to noetl-tools. 1074 tests; kind 32/32 (noetl/ops#369). Prod: flags off |
| 6 | noetl/tools#118, noetl/cli#107, noetl/worker#398 | **in PR**: `framework: remote` (NoETL agent endpoint, A2A subset) and `mcp_servers:` / `agents:` tool sources answered by the noetl-tools session on every runtime. Playbook-bound agent tools on the cluster remain item 8 |
| 5, 7 on local / daemon | noetl/cli#108 | **in PR**: `noetl serve` and `noetl subscribe --serve` serve the item 5/7 surface (`POST /mcp`, `/api/agents/*` with callbacks) on the local runtime and the daemon |
| 7 | noetl/server#565 | merged 2026-11-10 (server 3.155.0); kind e2e green; prod: `NOETL_AGENT_ENDPOINT` ON (no callback origins → every callback refused). Durable `/api/callbacks` and a gateway `/noetl/agents` route are follow-ups |
| 9 | noetl/server#566, noetl/cli#105 merged 2026-11-10 (server 3.156.0, cli 5.7.0); next slices open: server #567 → #568 → #569 (stacked), cli#106, gateway#66 | kind e2e green; prod: `NOETL_INSTANCE_REGISTRY` ON (empty allowlist → nobody admitted). Topology writer (`NOETL_EHGRAPH_TOPOLOGY_WRITER`) applied on prod 2026-11-10 (noetl/ops#367, PR still open). See "Item 9 as built" |
| 8 | — | not started |

## MCP + agents across runtimes (2026-11-10)

All PRs open, none merged; no prod change. Release order: noetl/tools#118 (publishes noetl-tools 4.5.0) → lock refresh + merge noetl/cli#107 → #108, noetl/worker#398 → noetl/ops#369.

| Direction | Local (`noetl run`) | Daemon (`noetl subscribe`) | Distributed |
|---|---|---|---|
| 1. call an external MCP server | REAL in PR (cli#107), local e2e | REAL in PR, daemon e2e | REAL in PR (worker#398), kind 32/32; prod gate `NOETL_TOOL_KIND_MCP` off |
| 2. call an external agent / MCP as agent tool | REAL in PR | REAL in PR | REAL in PR, kind; prod gates off. Playbook-bound tools: TARGET (item 8) |
| 3. playbook as MCP server | REAL in PR (cli#108 `noetl serve`) | REAL in PR (`subscribe --serve`) | REAL (item 5, prod flag on) |
| 4. playbook as agent with callback | REAL in PR | REAL in PR | REAL (item 7, prod flag on, no callback origins) |

Proof: tools 557 tests (16 new against stubs); cli 330 tests + `tests/e2e/mcp_agents/run.sh` 25/25 (real processes, each direction crossing local ↔ daemon); worker 1074 tests; kind `ci/kind/e2e_agents_mcp_runtimes.sh` 32/32 incl. local → cluster. The kind run found two cluster-only shapes (the server delivers `input:` as `args`, and adds `args: {}` to every tool), fixed in tools#118.

Still TARGET: playbook-bound agent tools on the cluster (item 8); durable tasks for `noetl serve`; gateway route for agents; A2A streaming / push; cluster → local calls (edge pull only). #330's general goal (the release pipeline telling a compatible addition from a breaking one) is unchanged.

## Item 9 as built (2026-11-09; rolled to prod 2026-11-10)

Prioritised by the owner as the central goal: NoETL instances, from a single box up to separate
clusters, register, discover each other and hand off work, using outbound calls only on the
instance side.

| Sub-piece | State | Notes |
|---|---|---|
| Instance identity | **REAL** | ML-DSA-87 (RustCrypto `ml-dsa =0.1.2`, not independently audited); id = `ni-` + hex(SHA-256(pk))[..16]; FIPS 204 context `noetl-instance/v1`; CLI and server share a test vector |
| Signed requests | **REAL** | purpose + audience + ts + nonce; replay cache fails closed; trust allowlist, default nobody |
| Register + heartbeat (outbound) | **REAL**, soft state | `POST /api/instances/register` is idempotent; lease from `NOETL_RUNTIME_TTL_SECS` (D8's rule); `noetl instance register` / `serve` |
| Discover API | **REAL** | signed `POST /api/instances/discover`; gated `GET /api/runtime/instances`; filters: tool kind, pool, site, label, playbook glob, runtime kind, accepts_tasks, liveness |
| Instance graph | **REAL**, live on prod (`NOETL_EHGRAPH_TOPOLOGY_WRITER`) | ehgraph `noetl-cluster` through `graph.upsert` / `graph.deactivate`: `registered_with`, `in_pool`, `can_run`, `knows`, `delegated_to`; tested against a real embedded graph |
| Pull-based handoff | **REAL**, soft state | submit → target long-polls inbox → local run → signed result → submitter polls or gets item 7's callback; leased claims, redelivery, stale results ignored |
| D8 mirror (`cli` / `daemon` kinds) | TARGET | ehdb `RuntimeKind` change; moves the three ehdb pins |
| Durable inbox | **REAL** in PR (server#567) behind `NOETL_INSTANCE_STORE=postgres` | write-through to `noetl.instance_tasks` (rev-guarded upsert), board rebuilt before routes serve; Postgres, not an EHDB feed subject, for this slice |
| Enrollment tokens (replace the pure allowlist) | **REAL** in PR (server#568, cli#106) behind `NOETL_INSTANCE_TRUST=enroll` | operator-minted one-time/n-use tokens (hash stored), redeemed with a signed `enroll` envelope; revoke; persisted with the store flag. Opaque tokens, not JWTs |
| Push delivery | **REAL** in PR (server#569, cli#106) behind `NOETL_INSTANCE_PUSH=true` + origin allowlist | per-registration push bearer; failed push → back to the pull inbox |
| Gateway route for instances | **REAL** in PR (gateway#66) behind `GATEWAY_INSTANCE_PROXY=on` | 8 signed routes passed through, operator routes never exposed, rate-limited |
| Topology writer in prod | **APPLIED** 2026-11-10 (ops#367, PR still open; the interop wiring in it is staged) | embedded ehgraph + GSM token; kind 11/11 on the same scripts |
| `kind: playbook` `runtime:` target | TARGET | |

Decisions recorded on noetl/server#566: identity scheme, allowlist vs enrollment, separate registry
vs D8, route shape.
