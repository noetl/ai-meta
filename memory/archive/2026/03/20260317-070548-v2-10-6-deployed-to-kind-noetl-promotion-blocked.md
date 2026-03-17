# v2.10.6 deployed to kind-noetl, promotion blocked
- Timestamp: 2026-03-17T07:05:48Z
- Author: Kadyapam
- Tags: noetl,release,v2.10.6,kind,gke,regression,blocked

## Summary
Deployed NoETL 2.10.6 to local kind-noetl using noetl build + noetl k8s deploy (image local/noetl:2026-03-16-23-56). Rollout succeeded for noetl-server and noetl-worker, server pod reports package version 2.10.6. Regression results: core hardening suite passed (20 tests), but broader regression checks failed due existing test harness/fixture issues (playbook_regression custom option bug and multiple composition/playbook-tool test failures). GKE promotion to gke_noetl-demo-19700101_us-central1_noetl-cluster not executed because success gate failed; also current principal lacks deployment read permissions in namespace noetl (container.deployments.get/list forbidden).

## Actions
-

## Repos
-

## Related
-
