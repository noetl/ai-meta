# 2026-11-11: MCP + agents in all runtimes (prod-enabled), catalog stack merged, item 8 / gateway agents / serve --task-db
- Timestamp: 2026-11-11T18:00:00Z
- Author: kadyapam (Claude session)
- Tags: interop,mcp,agents,catalog,prod,worker,server,gateway,cli,tools,rfc-539,rfc-548

## Summary
**MCP + agents across CLI, daemon and cluster** (merged ~00:04–01:00 UTC)
- tools#118 → noetl-tools 4.5.0 (crates.io): MCP auth/headers/`on_provider_error`, the remote agent framework (`/api/agents` + an A2A subset), and the `mcp_servers` / `agents` tool sources.
- cli#107 → v6.1.0: `kind: mcp` local and daemon.
- cli#108 → v6.2.0: `noetl serve` and `subscribe --serve`.
- worker#398 → v6.12.0: the #330 unpin (tools `=4.5.0`, async-nats 0.47) and `NOETL_WORKER_AGENT_TOOL`.
- ops#369: kind 32/32.

**PROD ENABLED ~01:13–01:23 UTC (user-approved)**
- `deploy/noetl-worker-rust` (user pool) → worker 6.12.0 `sha256:ac7cc50f…` with `NOETL_WORKER_AGENT_TOOL=true`.
- `sts/noetl-server-rust-embedded` (v3.156.2): `NOETL_TOOL_KIND_MCP=true`, then `NOETL_TOOL_KIND_AGENT=true`.
- The system pools and the cmdbus-writer stay on 6.11.9 `f866f614`, which is also the rollback pin.
- Rollback commands: ops#370, `ci/manifests/noetl/agents-mcp-prod/README.md`.

**Catalog #548 merged, all flags off, not on prod**
- server#572 → v3.157.0, #573 → v3.158.0, #574 → v3.159.0, #577 → v3.160.0 (`db://` + `ehdb://` resolvers).
- worker#399 → v6.13.0: WASM fuel / time / memory limits, default ON (`NOETL_WASM_FUEL`, `NOETL_WASM_TIMEOUT_MS`, `NOETL_WASM_MAX_MEMORY_MB`).

**Batch, flags off**
- worker#400 → v6.14.0: item 8, playbook agent tools as child executions (`NOETL_WORKER_AGENT_PLAYBOOK_TOOLS`).
- gateway#67 → v3.22.0: `/noetl/agents` (`GATEWAY_AGENTS_PROXY`).
- gateway#68 → v3.22.1: guest MCP run-limit bypass fixed.
- cli#109 → v6.3.0: `noetl serve --task-db`.
- Plan doc: ai-meta#550.

## Actions
- `NOETL_INSTANCE_TRUSTED_IDS` and `NOETL_AGENT_CALLBACK_ORIGINS` are still empty on prod. Populating them is the owner's decision.
- The cli release race: the v6.1.0 apt push and v6.2.0 brew push failed. A brew rerun fixed brew; apt has 6.2.0.

## Repos
- noetl/tools, noetl/cli, noetl/worker, noetl/server, noetl/gateway, noetl/ops

## Related
- ai-meta#539 (interop RFC), #548 (catalog), wiki Sessions-Log 2026-11-11 (day)
