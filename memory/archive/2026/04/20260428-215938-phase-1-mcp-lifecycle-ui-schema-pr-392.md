# Phase 1 — MCP lifecycle / discover / ui_schema PR #392
- Timestamp: 2026-04-28T21:59:38Z
- Author: Kadyapam
- Tags: mcp,catalog,api,architecture,phase1,pr

## Summary
Architecture Phase 1 (`sync/issues/2026-04-28-architecture-mcp-catalog-and-friendly-playbook-launcher.md`) landed as `noetl/noetl` PR #392 on branch `kadyapam/mcp-lifecycle-ui-schema-phase-1`, head `ab4a764c`. Adds the `noetl.server.api.mcp` module with three FastAPI endpoints and a workload-form inference utility, plus unit-test coverage for the inference rules and the lifecycle dispatch happy/error paths. Resource model unchanged — Mcp entries opt in via `spec.lifecycle` / `spec.discovery` / `spec.runtime` blocks; existing `/api/catalog/register` semantics untouched.

## Endpoints added
- `POST /api/mcp/{path:path}/lifecycle/{verb}` — resolves `spec.lifecycle.{verb}` to an Agent playbook path and dispatches it via `/api/execute`. Supports custom verbs beyond deploy/redeploy/restart/undeploy/status/discover; the schema-layer `coerce_lifecycle_verb` helper normalises but does not whitelist.
- `POST /api/mcp/{path:path}/discover` — two strategies: (a) when `spec.discovery.refresh_via` is set, dispatch that Agent and return the execution_id; (b) when `spec.discovery.tools_list_url` is set, fetch the URL, parse `tools`, diff against current `spec.tools`, re-register a new catalog version when changed (or always when `force=true`).
- `GET /api/catalog/{path:path}/ui_schema` — infers a workload form from raw YAML. Returns `UiSchemaResponse` with title, description_markdown, exposed_in_ui, and an ordered list of `UiSchemaField` rows.

## UI schema inference rules
- Default-value type → field kind: string / integer / number / boolean / object / array / null.
- `# ui:enum=[a,b,c]` → kind=enum, options populated.
- `# ui:secret` → secret=true, GUI masks input.
- `# ui:credential=pg_*` → credential picker filtered by glob.
- `# ui:description=...` → description copy.
- Nested mappings → kind=object with children populated recursively.
- ruamel.yaml is preferred (preserves comments); falls back to PyYAML when ruamel can't load the document, returning a flat schema with no directives.

## Tests
- `tests/unit/server/api/mcp/test_ui_schema_inference.py` — basic types, nested objects, secret/enum/credential directives, malformed YAML, unknown directive tolerance.
- `tests/unit/server/api/mcp/test_lifecycle_dispatch.py` — happy path, 422 missing-verb, 400 wrong-resource-kind.

## Open before merge
- Admin-role dependency on lifecycle endpoints (lifecycle.deploy etc. can nuke production MCP servers).
- Resource model docs in `repos/docs` describing `lifecycle`/`discovery`/`runtime` block contract.
- Smoke test against kind: register a fake Mcp resource → call lifecycle/deploy → confirm agent fires and returns an execution_id.
- Tool-list diff canonicalisation if real Mcp resources carry richer descriptors than `name` + `title`.

## Repos
- `repos/noetl`: branch `kadyapam/mcp-lifecycle-ui-schema-phase-1` at `ab4a764c`. PR `noetl/noetl#392` opened.

## Related
- Architecture: `sync/issues/2026-04-28-architecture-mcp-catalog-and-friendly-playbook-launcher.md`.
- Companion phases pending separate issues/PRs: Phase 2 (gateway shim), Phase 3 (ops templates), Phase 4 (GUI Mcp tab + run dialog + form generator), Phase 5 (docs + e2e).
