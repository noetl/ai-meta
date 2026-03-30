# noetl load test benchmark kind cluster
- Timestamp: 2026-03-28T03:10:51Z
- Author: Kadyapam
- Tags: issue-345,load-test,benchmark,kind,AHM-4288,performance

## Summary
Local kind cluster benchmarked with test_fetch_load.yaml (500 patients, 1767 pages). Fast run (min_delay~0.1s) completed in 4m05s as execution 592225635678815077 (playbook v12), 500/500 completed, 0 failed. Pure sleep floor=35s, NoETL overhead~3m30s (~119ms/page: loop orchestration, claim/event round trips, 100KB page transfer+parse, ResultRef hydration, Postgres write per patient). Infra tuned: server-deployment.yaml scaled to 2 replicas, Postgres max_connections=200 (sampled 31-35 in use), server pool_max=24 requests_waiting=0. CLI workload --set overrides do not survive state initialization in distributed runtime — had to register dedicated catalog version 12 for fast benchmark values instead of using --set. Active fixture remains test_fetch_load.yaml with prod defaults restored.

## Actions
-

## Repos
-

## Related
-
