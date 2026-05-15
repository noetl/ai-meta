# 2026-05-04 — Spike Gaps 2 + 5 merged

NoETL-as-AI-OS architecture spike progress: Gaps 1, 2, and 5 of 5 are
now landed in `noetl/noetl`. Gaps 3 + 4 remain.

## Landed

- **Gap 1** — `tool: agent framework=noetl` (`_invoke_noetl_playbook`
  helper in `noetl/tools/agent/executor.py`). Lets a `tool: agent`
  step dispatch a peer NoETL playbook as the agent runtime.
  4/4 smoke tests passed.

- **Gap 2** — playbook-as-MCP-server endpoint
  (`POST /api/mcp/playbook/{path:path}/jsonrpc`). New module
  `noetl/server/api/mcp/playbook_mcp.py` implements the MCP handshake
  on top of any registered playbook. `tools/call` dispatches via
  `/api/execute` and polls to terminal status. InputSchema derived
  from the existing `infer_ui_schema` so MCP tool schema = GUI
  workload form (no schema drift). Reads
  `metadata.exposes_as_mcp` as a soft signal (Gap 3 will harden it).
  8/8 smoke tests passed.

- **Gap 5** — `mcp/ollama` bridge (`noetl.tools.ollama_bridge`
  package). Thin MCP-protocol JSON-RPC server that fronts a local
  Ollama instance, exposes `chat` / `generate` / `list_models`.
  aiohttp preferred, urllib fallback. Catalog template included for
  one-curl registration as `mcp/ollama`. Self-troubleshoot playbooks
  (Gap 4) will call this for cheap-first inference, escalating to
  OpenAI / Claude only on low-confidence local results.
  9/9 smoke tests passed.

## Remaining

- **Gap 3** — Pydantic field for `metadata.exposes_as_mcp` (~30 LOC).
  Hardens the soft dict lookup that Gap 2 currently does. Lands in
  the catalog Pydantic models so registration validates the field
  shape rather than relying on payload introspection.

- **Gap 4** — self-troubleshoot playbooks themselves. Compose Gaps
  1+2+5: a playbook that classifies a failure with Ollama, fetches
  the relevant event log via the catalog, escalates to a stronger
  model when needed, returns a structured diagnosis. Two-phase:
  (a) the diagnostic playbook itself, (b) wiring it as the
  fallback for failed `tool: agent` calls.

## Sandbox testing pattern

PyPI is blocked from the sandbox so all three smokes use the same
hand-rolled stub harness: `importlib.util.spec_from_file_location` to
load the production module under test, plus `types.ModuleType` shims
for `fastapi.HTTPException` / `noetl.core.logger.setup_logger` /
adjacent service modules. Tests live in `scripts/*_smoke.py` so they
can be re-run as `python3 scripts/<name>_smoke.py` from any clean
checkout. Worth promoting to real pytest once the test environment
catches up.

## Pointer state

After the user bumps `repos/noetl`, ai-meta carries Gaps 1+2+5 in
the gitlink. Memory entry should be paired with that bump.

Tags: spike, mcp, ollama, ai-os, gap-2, gap-5, infrastructure
