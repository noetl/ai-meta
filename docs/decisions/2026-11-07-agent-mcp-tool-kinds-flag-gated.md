# Decision: `mcp` and `agent` become server tool kinds, gated per kind and OFF by default

- **Date:** 2026-11-07
- **Status:** Accepted (Phase 1, noetl/server#560, merged; amended by [2026-11-08 Phase 2](2026-11-08-mcp-phase2-worker-side-auth-and-catalog.md): the gates are open inside the wasm drive, noetl/server#561). The flags are not armed anywhere.
- **RFC:** [`docs/rfc/interop-topology-and-ai-mcp-playbooks.md`](../rfc/interop-topology-and-ai-mcp-playbooks.md)
- **Supersedes in part:** the #256 rule that `agent` and `mcp` are *unknown* tool kinds. The
  rule that **registration must not accept a kind that cannot execute** still stands. This
  decision is shaped by it.

## Context

`noetl_orchestrate_core::playbook::ToolKind` had 25 variants, without `mcp` or `agent`. Since
noetl/ai-meta#256, catalog registration rejects any step whose kind does not parse.

That was correct when written: neither kind had an executor behind the Rust server. The facts
have since diverged:

- **`mcp`.** The worker already executes it. Its pinned noetl-tools `=4.0.1` registers
  `McpTool` in `create_default_registry`, and the worker dispatches by kind string. The server
  enum is the only blocker. Live ops playbooks are blocked by it, for example
  `ops/automation/agents/kubernetes/runtime.yaml`.
- **`agent`.** The worker cannot execute it. `AgentTool` exists only in noetl-tools ≥ 4.1 and
  is not registered by `create_default_registry` in any release. The worker is held at 4.0.1
  (#330). Only the CLI runs `kind: agent`.

## Decision

1. Add `ToolKind::Mcp` and `ToolKind::Agent`. Each has **its own** flag, read once per process,
   armed only when the value is exactly `true`:
   - `NOETL_TOOL_KIND_MCP`
   - `NOETL_TOOL_KIND_AGENT`
2. **The gate is an authoring gate.** It applies where a playbook is authored:
   - `ToolKind::parse`, the registration validator's oracle;
   - `ToolSpec.kind` (`deserialize_with`), which `parse_playbook` hits at execute.

   It does **not** apply to `ToolCall.kind` (commands and events). History written while a
   gate was open stays readable after the gate is closed.
3. **With a flag off, behaviour is unchanged.**
   - Registration rejects the kind. The message now adds "recognised but disabled; `<FLAG>=true`
     enables it".
   - `valid_set()` does not advertise the kind.
   - Execute fails the `ToolDefinition` parse as before.

   So the `kind: mcp` / `kind: agent` rows #256 found in the live catalog do **not** become
   executable when this server ships.
4. **`NOETL_TOOL_KIND_AGENT` must stay off** until a worker that registers `AgentTool` ships
   (RFC Phase 6, Stage A). Turning it on earlier recreates #256: a kind that registers and can
   never run. `NOETL_TOOL_KIND_MCP` can be turned on in kind for the Phase 2 e2e.
5. Two "kind" namespaces still exist (#447): resource type (`kind: Mcp` documents) and tool
   kind (`tool.kind`). After this decision, `mcp` is valid in both **only when its flag is on**.

## Consequences

- No prod change. Nothing is armed, and the flags are absent from every manifest.
- Phase 2 can run the `kind: mcp` e2e in kind with one env var on the server. A good first
  target is the embedded ehgraph's own MCP endpoint.
- Rollback is unsetting the flag and restarting.
  - Registered `mcp` / `agent` playbooks then fail registration re-validation and execute
    parse again.
  - Their past commands and events still decode.
- The `ALL` array is 27 entries. `every_variant_is_in_all` round-trips the full vocabulary
  under `ToolKindGates::ALL_ON`, and checks that Display and Serialize agree.
