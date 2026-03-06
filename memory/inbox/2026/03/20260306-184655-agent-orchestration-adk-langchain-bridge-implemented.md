# agent orchestration adk langchain bridge implemented
- Timestamp: 2026-03-06T18:46:55Z
- Author: Kadyapam
- Tags: agents,noetl,adk,langchain,catalog,implementation

## Summary
Implemented first production slice for ai-meta agent orchestration in repos/noetl: new tool kind agent for ADK/LangChain/custom runtime invocation, worker dispatch wiring, and catalog discovery filters/endpoints for metadata.agent and metadata.capabilities.

## Actions
- Added `tool.kind: agent` to DSL validation in `repos/noetl/noetl/core/dsl/v2/models.py`.
- Added new `noetl/tools/agent` executor with:
- `framework` adapter modes (`adk`, `langchain`, `custom`).
- dynamic entrypoint loading via `module:attribute`.
- callable/factory entrypoint modes.
- payload-to-signature mapping for keyword and positional APIs.
- async/sync/async-generator materialization for ADK `Runner.run_async` style flows.
- Wired worker execution path in `repos/noetl/noetl/worker/v2_worker_nats.py` for `tool_kind == "agent"`.
- Extended catalog request schema/service with `path`, `agent_only`, and capability filters.
- Added dedicated discovery endpoint `POST /catalog/agents/list`.
- Hardened capability SQL filter with `jsonb_typeof(...)` guards and `meta` fallback for agent flags/capabilities.
- Added focused tests:
- `tests/tools/test_agent_executor.py`
- `tests/api/test_catalog_agent_filters.py`
- `tests/api/test_catalog_agents_endpoint.py`
- `tests/unit/dsl/v2/test_tool_spec_agent.py`
- Validated with:
- `pytest -q tests/tools/test_agent_executor.py tests/api/test_catalog_agent_filters.py tests/api/test_catalog_agents_endpoint.py tests/unit/dsl/v2/test_tool_spec_agent.py` (11 passed).
- `python3 -m compileall noetl/tools/agent noetl/server/api/catalog noetl/worker/v2_worker_nats.py`.
- Committed in `repos/noetl` on branch `codex/agent-orchestration-adk-langchain` as `896864b0`.

## Repos
- repos/noetl

## Related
- docs: `repos/docs/docs/ai-meta/agent-orchestration.md`
