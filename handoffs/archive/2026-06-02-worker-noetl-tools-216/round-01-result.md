---
slug: 2026-06-02-worker-noetl-tools-216
round: 01
status: complete
pr: https://github.com/noetl/worker/pull/36
branch: kadyapam/tools-216-nats-mcp-dispatch
wiki_commit: noetl-worker-wiki@6e8413d
tracks: noetl/ai-meta#40
---

## Summary

PR: https://github.com/noetl/worker/pull/36  
Branch: `kadyapam/tools-216-nats-mcp-dispatch` (noetl/worker)

## Version bump

`Cargo.toml`: `noetl-tools = "2.11"` → `"2.16"` (line 37).  
`[patch.crates-io]` block added (lines 117–129) pointing to `../../repos/tools` because `2.16.0` had not yet published to crates.io at authoring time (only `2.15.0` was live). Block includes a `REMOVE` instruction for post-publish cleanup.

Versions picked up: 2.12–2.14 (internal / dep realignment), **2.15.0** (`NatsTool`, noetl/tools#12), **2.16.0** (`McpTool`, noetl/tools#13).  No breaking-change surface in the worker's existing API (`ToolRegistry`, `ToolConfig`, `ExecutionContext`, `create_default_registry`).

## Changes

- `Cargo.toml` — dep bumped + comment updated + `[patch.crates-io]` + `uuid` dev-dep for test bucket naming.
- `README.md` — dep version updated (`2.8.7` → `2.16`).
- `tests/dispatch_nats_mcp.rs` — 9 new tests (see below).

## Test coverage (tests/dispatch_nats_mcp.rs)

Unit (always run): `registry_has_nats_tool_kind`, `registry_has_mcp_tool_kind`, `registry_still_has_pre_existing_tool_kinds`, `dispatch_duration_histogram_accepts_{nats,mcp}_label`, `dispatch_errors_counter_accepts_{nats,mcp}_label` — confirms metric labels surface in `/metrics` text output.

Integration (env-gated): `nats_dispatch_kv_roundtrip_via_registry` (`NOETL_TEST_NATS_URL`) and `mcp_dispatch_health_probe_via_registry` (`NOETL_TEST_MCP_ENDPOINT`).

93 pre-existing unit tests pass + 9 new tests pass (`cargo test -- --test-threads=1`). `cargo clippy --all-targets` clean (no new warnings).

## Docs

Wiki page `nats-mcp-tool-kinds.md` added (`repos/noetl-worker-wiki/nats-mcp-tool-kinds.md`) — playbook config shapes, credential wiring, endpoint resolution, dispatch path, and observability notes. Cross-linked from `Home.md` (Pages section) and `_Sidebar.md`. Pushed to `noetl/worker.wiki` at `6e8413d`.

## Observability check

`command.execute` span in `src/executor/command.rs:192-199` still carries `execution_id = command.execution_id` after the dep bump — no change to that span. Principle 4 satisfied.

## Blockers

- `[patch.crates-io]` block must be removed once `noetl-tools 2.16.0` publishes to crates.io (PR description calls this out explicitly).
- Kind-cluster validation per `agents/rules/deployment-validation.md` deferred to the ai-meta pointer-bump step.
