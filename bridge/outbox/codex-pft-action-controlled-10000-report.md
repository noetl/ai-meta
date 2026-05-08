# PFT Action-Controlled 10k Validation Report

## Goal

Deploy the merged `noetl/e2e#17` playbook version, rerun the PFT end-to-end flow, and verify that the flow processes 10,000 patients in under one hour using controlled NoETL actions rather than an external database script.

## Outcome

- Verdict: GREEN
- Cluster: `gke_noetl-demo-19700101_us-central1_noetl-cluster`
- NoETL server/worker image: `ghcr.io/noetl/noetl:v2.37.1`
- PFT fixture server image: `ghcr.io/noetl/test-server:e2e-3b7dde6`
- e2e commit deployed: `b0ae122ae119be8bcc71f8dea9be76db0d179675` (`fix(pft): write validation log from final aggregate (#17)`)
- Registered catalog path: `fixtures/playbooks/pft_flow_test/test_pft_flow`
- Registered catalog version: `24`

## Execution Evidence

- PFT execution: `621993877326528945`
- Status: `COMPLETED`
- Started: `2026-05-08T04:30:48.412327Z`
- Finished: `2026-05-08T04:32:41.392808Z`
- Duration: `112.98s` (`1m 53s`)
- Final `check_results` row:
  - `status`: `passed`
  - `facilities_checked`: `10`
  - `patients_per_facility`: `1000`
  - `all_data_types_complete`: `true`
  - `mds_complete`: `true`

## Table Verification

Verification was run through a NoETL `postgres` action probe, not by an uncontrolled direct database script.

- Probe catalog path: `tmp/pft_merged_summary_probe`
- Probe execution: `621995558017696648`
- Probe status: `COMPLETED`

Table totals:

- Facilities: `10`
- Assessments: `10000`
- Conditions: `10000`
- Medications: `10000`
- Vital signs: `10000`
- Demographics: `10000`
- MDS expected: `10000`
- MDS details done: `10000`

Queue totals for execution `621993877326528945`:

- Assessments queue done: `10000`
- Conditions queue done: `10000`
- Medications queue done: `10000`
- Vital signs queue done: `10000`
- Demographics queue done: `10000`

Validation log:

- `pft_test_validation_log` rows: `10`
- Per-facility min/max for assessments, conditions, medications, vital signs, demographics, assessments queue, MDS expected, and MDS details: `1000/1000`
- `actual_tables_pass`: `true`
- `queue_tables_pass`: `true`
- `validation_log_pass`: `true`

## What Worked

- `noetl/e2e#17` was fast-forwarded into `repos/e2e` and registered as catalog version `24`.
- The merged playbook processed the full 10-facility, 10,000-patient fixture in `1m 53s`, comfortably under the one-hour target.
- The final validation no longer depends on templating validation JSON from prior step output; it reads aggregate PFT table state through a declared `postgres` action.
- The new validation-log polish works: `pft_test_validation_log` is populated with one row per facility after the final aggregate check.
- The publicly available versioned fixture server image remained usable on GKE.

## Issues And Workarounds

- Earlier pre-#17 validation proved the domain tables were complete but `pft_test_validation_log` stayed empty. `noetl/e2e#17` fixed this by inserting the final aggregate validation rows after the correctness guard passes.
- A previous stale batch-size-100 execution from before the cursor/concurrency fixes remained outside this validation path. It was not deleted or modified.
- No GUI deployment was involved. On GKE, the GUI is expected to come from Cloudflare Pages; this test only needed NoETL server/worker and the PFT fixture server.

## Notes For Claude

The current GKE flow is no longer bottlenecked by the original cursor/concurrency behavior. With `pft_batch_size: 25`, `pft_batch_concurrency: 16`, public fixture image `ghcr.io/noetl/test-server:e2e-3b7dde6`, and the final aggregate validation-log insert from `e2e#17`, the PFT playbook is an end-to-end GREEN for 10,000 patients under one hour.

For the next pass, the useful hardening target is operational cleanup/observability around stale historical executions rather than the happy-path PFT mechanics. The controlled-action path is doing what the user asked: HTTP fetch, postgres persistence, and final table/log verification all stay inside NoETL tools.
