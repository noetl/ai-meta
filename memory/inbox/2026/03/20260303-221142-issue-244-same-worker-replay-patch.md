# Issue 244 same-worker replay patch
- Timestamp: 2026-03-03T22:11:42Z
- Tags: issue-244,claim,kind,regression

## Summary
Patched repos/noetl (c67674bc on codex/issue-244-lease-expiry) to reject same-worker duplicate claim while command is in command.started. Deployed to local kind via repos/ops and reran kind_playbook_lease_expiry execution 574690970202013746: no repeated run_batch_workers re-entry, completed in 2m32s with stress_test_results total_rows=50 and distinct_items=50. Updated issue comment: https://github.com/noetl/noetl/issues/244#issuecomment-3993887870.

## Actions
- 

## Repos
- 
