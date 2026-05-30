# R-1.1 complete: noetl-executor crate shipped
- Timestamp: 2026-05-30T05:37:01Z
- Author: Kadyapam
- Tags: r-1.1 noetl-executor strategy-b tools-bridge h10 milestone

## Summary
All 8 sub-PRs landed on noetl/cli (PR-2a, PR-2b, PR-2c-1 through PR-2c-8, PR-2d). repos/cli/executor/ is a workspace member crate hosting shared utilities for CLI + worker: playbook types, template/condition engines, capability validation, event envelope, credential resolver trait, tools_bridge onto the noetl-tools registry, and a worker-only CommandSource scaffold. playbook_runner.rs went from 2,688 to 1,606 LoC (-1,082 net, -40%). 174 workspace tests passing (80 noetl-executor unit + 12 noetl-executor integration + 41 noetl + 41 ntl). Tool kinds wired through registry: Rhai, Shell, Http, DuckDb (full registry round-trip with envelope reshape helpers per kind). Tool kinds staying inline per § H.10 with pure helpers extracted: Playbook (prepare_sub_playbook_vars), Auth (resolve_auth_to_bearer + auth_context_updates), Sink (format_sink_payload + json_to_csv). 0 semantic regressions; 1 feature gain (DuckDB params binding in PR-2c-6 — was silently dropped pre-migration). Key architectural finding § H.10 settled mid-R-1.1: CLI tree walker and worker pull loop are fundamentally different control loops; flattening either produces more abstraction than it removes. Crate re-scoped from control-loop to utilities-and-types. Wiki page noetl-cli-wiki/executor-crate-architecture.md has the full sub-PR landing-history + semantic-divergence tables. noetl/cli#19 auto-closed via PR #31's Closes keyword. Umbrella noetl/ai-meta#30 stays open through R-1.2 / R-1.3 (worker adoption), R-2 (Apache Arrow data plane), R-3 (object_store; includes GCS sink migration tracked as noetl/ai-meta#31). All ai-meta pointer bumps committed locally f9323d7 / 86d658e / 3933f47 / 7a3b707 / 80e1a86 / 39e9c5f; not yet pushed to origin per the explicit-push-only policy.

## Actions
-

## Repos
-

## Related
-
