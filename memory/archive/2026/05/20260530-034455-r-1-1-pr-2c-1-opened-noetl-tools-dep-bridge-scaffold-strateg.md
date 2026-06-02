# R-1.1 PR-2c-1 opened: noetl-tools dep + bridge scaffold (Strategy B start)
- Timestamp: 2026-05-30T03:44:55Z
- Author: Kadyapam
- Tags: rust,tools-bridge,strategy-b,issue-30,pr-23,r1-1-pr2c-1

## Summary
First of ~8 incremental sub-PRs for replacing CLI's inline tool execution. PR noetl/cli#23 adds noetl-tools = 2.8.7 dep to noetl-executor (matches worker pin) + executor/src/tools_bridge.rs scaffold with BridgeOutcome + dispatch_via_registry stub. No CLI call site changes; bridge stub returns None for any Tool kind. 1 new test (tools_bridge::tests::dispatch_via_registry_stub_returns_none). Workspace test count 16 -> 17 passing. First compile 2m29s (kube + k8s-openapi + duckdb bundled). Cargo.lock +1283 lines. Subsequent sub-PRs (PR-2c-2..PR-2c-8) replace one tool kind per PR — noop -> rhai -> shell -> http -> duckdb -> playbook -> auth/sink bridge. Strategy B prevents the semantic-divergence risk from materializing all at once.

## Actions
-

## Repos
-

## Related
-
