# Memory Timeline

## 2026-03

- Initialized `ai-meta` with submodules, agent docs, and memory workflow.
- Compaction `20260303-192541` from inbox entries.
- Compaction `20260317-181821` from inbox entries.
- Rolled out NoETL `v2.10.10` to `gke_noetl-demo-19700101_us-central1_noetl-cluster` and recorded Adiona.org project context note for `noetl-demo-19700101`.
- Rolled out NoETL `v2.10.15` to `gke_noetl-demo-19700101_us-central1_noetl-cluster` via `repos/ops` GKE playbook after ai-meta/submodule refresh.
- Implemented CLI gateway-auth UX improvements and REPL console prompt flow, with docs updates in `repos/cli` and `repos/docs`.

## 2026-04

- Compaction `20260402-183017` from inbox entries.
- Compaction `20260406-103434` from inbox entries.
- Split NoETL integration fixtures into dedicated `noetl/e2e`, added e2e docs/registration, and updated ops fixture references.
- Released NoETL `v2.23.2` with typed execution observability responses, AI explain fixes, and execution API review fixes.
- Shipped GUI terminal workspace releases through `noetl/gui` PRs `#7..#9`, including runtime env injection, GHCR image releases, resizable terminal/dashboard panes, and deployed `ghcr.io/noetl/gui:v1.0.6` to local kind via ops.
- Established next MCP integration direction: deploy MCP servers through ops and connect GUI terminal commands to available MCP services, starting with `containers/kubernetes-mcp-server`.
- Implemented MCP-as-agent-playbook draft PR set across `repos/noetl`, `repos/ops`, `repos/gui`, `repos/gateway`, and `repos/docs`; local kind validation completed Kubernetes MCP `tools/list` and `pods_list_in_namespace` through NoETL agent executions.
- Repaired GKE Gateway Auth0 login by refreshing the `auth0_login` system playbook result-envelope handling in `repos/e2e`, registering it on GKE, documenting the deployment/troubleshooting path in `repos/docs`, and recording the no-secret operational guidance.

## 2026-05

- Closed the GKE Vertex AI triage arc through NoETL `v2.37.1`, including adaptive diagnosis-fetch telemetry and recursive projection preservation.
- Reworked the PFT fixture from cursor-heavy patient/page orchestration to action-controlled bounded batches; validated 10,000 patients on GKE in `1m 53s` and on local kind in `54s`.
- Documented the PFT speedup in `repos/e2e/fixtures/playbooks/pft_flow_test/SPEEDUP_EXPLANATION.md` and opened `noetl/ops#47` so local kind deploys build the test-server from `repos/e2e` instead of the stale noetl fixture path.
