# Decision: `kind: mcp` auth, catalog resolution and error policy live in the worker

- **Date:** 2026-11-08
- **Status:** Accepted. Phase 2 of the RFC: noetl/worker#397, noetl/server#561, noetl/ops#364. Nothing is armed in prod.
- **RFC:** [`docs/rfc/interop-topology-and-ai-mcp-playbooks.md`](../rfc/interop-topology-and-ai-mcp-playbooks.md) §3.1
- **Amends:** [`2026-11-07-agent-mcp-tool-kinds-flag-gated.md`](2026-11-07-agent-mcp-tool-kinds-flag-gated.md), on where the gate is read.

## Context
The RFC placed `server: mcp/<path>` resolution in the server, at command-build time, and `Authorization`
support in noetl-tools' `McpTool`. Two facts moved both:

- **Commands are built in two places.** The server builds them, and so does the off-server orchestrate drive
  (wasm, on a worker). A server-side resolver would miss every follow-up step the drive builds.
- **The worker is exact-pinned to noetl-tools `=4.0.1`** (async-nats graph, #330). That `McpTool` hard-codes
  its headers, so header support in a new tools release would not reach the worker.

## Decision
1. **Resolve `server: mcp/<path>` on the worker, at dispatch.**
   - It applies to an `mcp` step with no endpoint whose `server` starts with `mcp/`.
   - The worker requires the catalog entry to be `kind: Mcp` and injects `spec.url` (http/https only).
   - Failures are classified like credential aliases: a missing or invalid resource is terminal; an outage retries.
2. **A worker `mcp` tool replaces tools' `McpTool` in the worker registry.**
   - It sends `auth` (alias or inline `AuthConfig`) and `headers` (keychain templates allowed).
   - A step with neither is **delegated unchanged** to tools' `McpTool`.
   - Header values are sensitive, never logged, and never in the result; the result carries `sent_headers` (names only).
3. **`on_provider_error: fail | continue` is a per-step override** of `NOETL_PROVIDER_ERROR_TERMINATES`.
   - With `fail`, an `mcp` transport error (`status: "error"`) also fails the step.
   - The key is stripped before dispatch, and an unknown value is a terminal config error.
4. **The tool-kind gates are open inside the wasm drive** (`ToolKindGates::for_target`).
   - The gate is enforced where a playbook is *admitted*: registration and the server's execute-time parse, both native.
   - The drive has no environment and only decodes playbooks the server admitted.
   - Reading the gates there closed them, and broke every `mcp` execution.
5. **Server and worker changes are typed `chore`**, so neither cuts a release. Prod manifests set no new flag.
   `NOETL_TOOL_KIND_MCP` is armed in kind only, by the e2e, for its duration.

## Consequences
- `kind: mcp` runs end to end in kind (23/23) against the embedded ehgraph MCP endpoint, with auth.
  - The roundtrip has its results on the event log.
  - The refusal path fails the run.
- **Duplication.** The worker carries a second MCP client (about 200 lines) until the tools pin lifts. Then
  header support should move upstream into `McpTool`, and the worker tool should shrink to a delegate.
- **Known gaps.**
  - A nested `mcp` sub-task inside `task_sequence` dispatches through tools' internal registry, so it gets no auth.
  - Resource-level credentials (`spec.auth` on the `kind: Mcp` document) are not read.
- **Open.** One unexplained `start`-step loop, in 1 of 6 e2e runs, is recorded in the ops BUILD_LOG.
- **`NOETL_TOOL_KIND_AGENT` stays off.** No worker registers `AgentTool` yet (Phase 6).
