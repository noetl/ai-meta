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
- Compaction `20260515-173703` from inbox entries.
- Compaction `20260523-052525` from inbox entries.
- Compaction `20260524-002005` from inbox entries.
- Compaction `20260524-055140` from inbox entries.
- Compaction `20260526-063333` from inbox entries.
- Compaction `20260529-024139` from inbox entries.

## 2026-06

- Compaction `20260602-012917` from inbox entries.
- Compaction `20260609-025209` from inbox entries.
- Bootstrapped EHDB (`repos/ehdb`) as the NoETL Event Horizon Database
  submodule and `repos/ehdb-wiki` as its design wiki; opened initial
  EHDB issues #1-#5 for Rust workspace/CI, catalog model, object
  storage, transaction log/MVCC, and NoETL integration planning.
- Refined EHDB scope as a NoETL-domain storage system, not a generic
  database: future EHDB should cover NoETL catalog/metadata, streams
  replacing NATS JetStream, RAG/retrieval replacing permanent Qdrant,
  analytical reads replacing ClickHouse role, and storage/system-record
  paths replacing ordinary PostgreSQL/object-store platform
  dependencies; tracked in `noetl/ehdb#6`.
