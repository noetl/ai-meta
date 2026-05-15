# cursor-loop infrastructure landed; PFT multi-facility race remains
- Timestamp: 2026-04-21T19:16:10Z
- Author: Kadyapam
- Tags: cursor-loop,pft,race,template-rendering,noetl

## Summary
Cursor-driven loop primitive (loop.cursor, mode=cursor, max_in_flight=worker concurrency) is complete and proven for single-facility PFT runs. Infrastructure on feat/storage-rw-alignment-phase-1: CursorSpec/Loop pydantic model with mutual-exclusion validator, noetl.core.cursor_drivers registry + PostgresCursorDriver sharing an AsyncConnectionPool per DSN/process (size-bumped to options.pool_size, default 8), _issue_cursor_loop_commands dispatching N task_sequence-suffixed commands with tool.kind=cursor_worker, pre-rendered claim SQL at dispatch time (with worker-side fallback), seeded loop_state in both memory and NATS KV, completed_steps cleanup on re-entry, cursor_worker runtime opening the driver and looping claim -> TaskSequenceExecutor -> continue until drain, events.py/rendering.py cursor-aware guards for collection re-render and tail-repair. PFT playbook migrated: 5 fetch_X cursor loops replace 15 load/claim/fetch steps. loop.done fires correctly (proven by mark_X_done running per facility completion). Multi-facility run 609862626536849455 got facilities 1, 2, 7 fully green (1000/1000 × 5 data types) but 3-6 were skip-marked via a PRE-EXISTING playbook-level race on SELECT active=TRUE LIMIT 1 subqueries during rapid facility transitions. Attempt to thread ctx.facility_mapping_id hit a separate template-rendering mismatch (load_next_facility.set with output.data.rows[0]... renders to TaskResultProxy AttributeError) — reverted. The multi-facility race and the step-set template rendering path are orthogonal to cursor loops and tracked as follow-ups.

## Actions
-

## Repos
-

## Related
-
