# EHDB Claude continuation handoff

Date: 2026-07-04 UTC

Created the EHDB continuation handoff for Claude:

- GitHub issue: https://github.com/noetl/ehdb/issues/234
- Wiki page:
  https://github.com/noetl/ehdb/wiki/Claude-Handoff-EHDB-NoETL-Integration
- Project board:
  https://github.com/orgs/noetl/projects/4/views/1
- EHDB wiki commit:
  `9fc0dd82484ad27d11e32a7c80d73cae72a71b77`

The handoff page covers:

- Current EHDB and NoETL integration pointers.
- Implemented EHDB foundation and NoETL integration slices.
- Open umbrella issues for phases 0-4 and dependency-collapse scope.
- Next phases A-G: ops/runtime enablement, worker/playbook readiness,
  EHDB stream integration, system WASM store integration, RAG retrieval
  integration, distributed durability/replication, and analytical query
  path.
- Architectural decisions to preserve: EHDB is NoETL-specialized,
  catalog lives inside EHDB, gateway/API/server are control-plane-only,
  data touch belongs in bounded worker/playbook/system steps, no
  persistent per-tenant agent/MCP processes, system WASM hot replacement
  uses digest/revision bindings, and geo/data-gravity metadata remains
  storage routing metadata.
- EHDB, NoETL, image, and kind validation commands.
- A copy-paste Claude chat prompt that starts with Phase A: disabled by
  default ops/runtime enablement for EHDB env in NoETL deployments.

Pointer state: `repos/ehdb-wiki` should point at
`9fc0dd82484ad27d11e32a7c80d73cae72a71b77`.
