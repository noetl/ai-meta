# Issue 244 regression executed on kind
- Timestamp: 2026-03-04T01:33:42Z
- Tags: noetl,issue-244,kind,regression,test

## Summary
Deployed noetl commit f8e380b8 to kind via ops automation, registered and executed parallel_distributed_claim_regression playbooks, and verified no duplicate batch runs (duplicate_offsets=0, max_runs=1, 200/200 results).

## Actions
- Redeployed NoETL to kind using ops playbook:
  - `noetl run automation/development/noetl.yaml --runtime local --set action=redeploy --set noetl_repo_dir=../noetl`
- Registered regression playbooks against local server (`127.0.0.1:8082`):
  - `parallel_distributed_claim_regression_worker@1`
  - `parallel_distributed_claim_regression@1`
- Executed regression:
  - execution_id `574791590036636403`
  - duration `3m 29s`
  - completed `true`, failed `false`
- Verified DB outcomes in `demo_noetl.public`:
  - `stress_test_results`: `cnt=200`, `distinct_cnt=200`
  - `stress_test_batch_runs`: `max_runs=1`, `duplicate_offsets=0`
- Posted evidence comment on issue #244:
  - https://github.com/noetl/noetl/issues/244#issuecomment-3994673719

## Repos
- noetl/noetl (`codex/issue-244-lease-expiry`, commit `f8e380b8`)
- noetl/ai-meta (this memory entry)
