---
slug: 2026-06-02-mcp-tool-kind
round: 01
status: complete
date: 2026-06-01
tracks: noetl/ai-meta#39
---

## Phase A — Implementation

**Branch:** `feature/mcp-tool-kind` in `noetl/tools`
**PR:** https://github.com/noetl/tools/pull/13
**Commits:** `3f2e8fc` (feat), `bb3e48e` (version bump to 2.16.0)

New file: `src/tools/mcp.rs` (≈580 LoC source, ≈750 LoC tests).
Modified: `src/tools/mod.rs` (4 lines — `mod mcp`, `pub use`, registry entry).

Operations implemented: `tools/call`, `tools/list`, `health`, passthrough.
Endpoint resolution: `config.endpoint` → `NOETL_MCP_<SERVER>_ENDPOINT` env → `NOETL_MCP_URL`.
Session lifecycle: POST `initialize` → capture `Mcp-Session-Id`; stateless servers tolerated.
Timeout chain: `config.timeout` → `NOETL_MCP_REQUEST_TIMEOUT_SECONDS` → 60s, clamped to `NOETL_WORKER_COMMAND_TIMEOUT_SECONDS`.
SSE parsing: `parse_mcp_envelope` at `src/tools/mcp.rs:271`.
Text extraction: `extract_text` at `src/tools/mcp.rs:307`.
Observability: `mcp.op` span with `method` + `server` + `execution_id`; health at DEBUG; failures at WARN with `execution_id`.
Return shape matches Python tool (`status`, `server`, `endpoint`, `method`, `tool?`, `arguments?`, `text`, `result`, `initialize`, `error?`).

## Phase B — Tests

32 unit tests in `src/tools/mcp.rs::tests` (line 767+).
Coverage: envelope parsing (JSON + SSE), endpoint resolution chain, server env name conversion, timeout clamping logic, health URL derivation, method param building for all three branches, `McpTool::name()`.
Integration tests gated behind `NOETL_TEST_MCP_ENDPOINT`.
`cargo test --lib`: 202 passed, 0 failed.
`cargo clippy`: no new warnings.

## Phase C — Wiki

New page: `repos/noetl-tools-wiki/mcp-tool.md` (wiki SHA `8a02d8d`).
Cross-linked from `Home.md` (tool kinds table + Pages section + Versioning) and `_Sidebar.md`.
Live at: https://github.com/noetl/tools/wiki/mcp-tool

## Blockers / next steps

None.  Awaiting PR review and merge.  Once merged:
1. ai-meta pointer bump: `chore(sync): bump tools-wiki to 8a02d8d` + `chore(sync): bump tools to <merge-sha>`.
2. Close noetl/ai-meta#39 with closing comment citing noetl/tools#13 + pointer-bump SHA.
3. Worker-side wiring (new `ToolKind::Mcp` variant in `noetl/worker`) is out of scope for this round — tracked separately per issue #39.
