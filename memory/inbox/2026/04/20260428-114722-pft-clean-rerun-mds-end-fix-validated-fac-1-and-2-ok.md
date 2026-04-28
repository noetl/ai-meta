# PFT clean rerun — MDS end-step fix validated, facilities 1 and 2 GO
- Timestamp: 2026-04-28T11:47:22Z
- Author: Kadyapam
- Tags: pft,kind,mds,fix-validated,observability,worker-pool

## Summary
Fresh `tests/fixtures/playbooks/pft_flow_test/test_pft_flow` execution `614955937991754550` started at 11:27:40Z on local kind via the gateway at `http://722-2.local:8082`. Sub-playbook `tests/fixtures/playbooks/pft_flow_test/test_mds_batch_worker` registered as version 7 (catalog_id `614955771628880693`) with the `workload.*` reference fix in the `end` step. By ~19 min wall clock the parent has finished facilities 1, 2 and 3 (now on facility 4); `pft_test_validation_log` shows facilities 1 and 2 at the GO criterion `1000/1000` for assessments, conditions, medications, vital_signs, demographics, with `total_expected = 1000`. Patient-loss race condition is not triggering. The original `invalid literal for int() with base 10: '{{ start.batch_number }}'` failure mode is gone.

## Actions
- Probed kind: localhost ports refuse, but the gateway is bound on the Mac mDNS name `http://722-2.local:8082` (consistent with `api_base_url` baseline in current.md).
- Discovered noetl gateway endpoints (`/api/catalog/register`, `/api/catalog/list`, `/api/catalog/resource`, `/api/execute`, `/api/executions[/{id}[/status|/events]]`, `/api/postgres/execute`, `/api/pool/status`, `/api/worker/pools`).
- Registered patched sub-playbook content (base64 form) at path `tests/fixtures/playbooks/pft_flow_test/test_mds_batch_worker` (v7).
- Triggered parent flow via `/api/execute` → execution `614955937991754550`.
- Polled execution + spawned sub-execs continuously; verified per-facility `pft_test_validation_log` rows via `/api/postgres/execute` with credential `pg_k8s`.

## Findings
- **Fix works**: zero `int()` template-literal errors in any sub-execution; sub-playbook reaches `end` step and emits the expected result.
- **Validation log (latest snapshot)**: facilities 1 and 2 = `1000/1000` across all 5 data types, `total_expected = 1000`. Facility 3 row delayed only by Postgres pool saturation in our query path (gateway pool returned `too many clients already` mid-run; not a flow failure).
- **Pre-existing orthogonal issue (not the fix)**: 3+ sub-execs sit at top-level status `RUNNING` forever despite `end` already being in `completed_steps` and step duration being seconds. Parent run still advances (uses `call.done`), so the bug is in sub-execution status reconciliation, not in flow control. Matches the "noetl status --json shows completion_inferred=true with sparse completed_steps even when /api/executions/{id} is terminal/complete" item in current.md.
- **Worker pool reality**: only 3 workers `ready` in `/api/worker/pools` (capacity 1 each); 208 `offline` entries. test_pft_flow comment assumes "3 × 16 in-flight = 48 capacity"; actual is 3 × 1 = 3 concurrent slots, which explains slower-than-expected pacing (~5–10 min per facility instead of 3).

## Repos
- `repos/e2e` topic branch `kadyapam/pft-mds-end-step-workload-ref` at `eb9108b fix: reference workload.* in mds batch worker end step` (local-only; not yet pushed to `noetl/e2e`).
- `repos/noetl` and `repos/gateway` and `repos/gui` and `repos/ops` ai-meta gitlinks already bumped earlier in this session (commit `9faf15b`).

## Final outcome (added 2026-04-28 ~12:00Z)
Parent `614955937991754550` terminated **FAILED** at 21m21s during facility 4's `run_mds_batch_workers` (end_time `11:49:01.575Z`). Final `pft_test_validation_log` shows facilities 1, 2, 3 all at the GO criterion `1000/1000` for all 5 data types — facility 4 never wrote a row because the MDS step was the last hop before `validate_facility_results`.

The MDS-end-step `int()` literal-template bug is **fixed** (50 sub-execs COMPLETED, 0 sub-execs FAILED across the whole run; the patched `end` step never crashed). The new failure is a **different, orthogonal issue**:
- Cluster of `command.failed` + `call.error` events on `run_mds_batch_workers` at 11:49:01, all with empty error messages.
- `failed_event_count: 0` in the analyze view (no leaf failure to attribute).
- 495 retry attempts (99 each on fetch_assessments / fetch_conditions / fetch_medications / fetch_vital_signs / fetch_demographics task_sequences) — the data-fetch loop was retrying heavily before death.
- Only 3 workers `ready` (capacity 1 each) backing this run; 208 `offline` zombie entries in the pool table.

Most plausible root cause: dispatch-level timeout / NATS pull starvation in `run_mds_batch_workers` for facility 4, exacerbated by the scarce worker pool. The flow's own commentary calls out the deadlock risk at 5 parent slots × 5 child slots when the available worker count drops below ~3 × 16. This run had 3 × 1 = 3 capacity, well under the assumed budget.

## Open follow-ups
- Wait for parent execution `614955937991754550` to reach a terminal state and capture full `pft_test_validation_log` (10 rows, all `1000/1000`) for the GO/NO-GO note.
- Push `repos/e2e` topic branch upstream, open PR, after merge bump ai-meta gitlink.
- File a separate noetl issue/PR for the input renderer scope on `loop.done`-arc destinations (still the right long-term fix).
- File a separate noetl issue for sub-execution top-level status not transitioning to COMPLETED after the `end` step finishes when the parent advances via `call.done`.
- Clean up the 208 stale `offline` worker pool entries in `/api/worker/pools`; or add a worker scale-up so `max_in_flight: 5` in run_mds_batch_workers actually matches available capacity.

## Related
- Parent execution: `614955937991754550` (RUNNING, 19m34s, facility 4 `setup_facility_work`).
- Failed parent (prior, with bug): `614768929377878676` (FAILED, 29m3s).
- Sub-execs (sample): `614957275840513005` COMPLETED 27s, `614957275823735788` COMPLETED.
- Issue: `sync/issues/2026-04-28-bug-mds-batch-worker-end-step-template-hydration.md`.
