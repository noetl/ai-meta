# Neutral synthetic state-report load fixture merged
- Timestamp: 2026-03-24T14:26:26Z
- Author: Kadyapam
- Tags: noetl,load-test,fixtures,synthetic,github:320

## Summary
Merged noetl/noetl#320 after removing private BHS naming from the public repo. Added tests/fixtures/playbooks/load_test/state_report_synthetic_load/{state_report_synthetic_load,state_report_synthetic_load_worker}.yaml, README, and tests/scripts/test_state_report_synthetic_load.py. The fixture now fails on count mismatch, uses sanitized inputs in SQL, registers both main and worker playbooks, and gives a public synthetic load/repro harness close to the state-report workflow shape.

## Actions
-

## Repos
-

## Related
-
