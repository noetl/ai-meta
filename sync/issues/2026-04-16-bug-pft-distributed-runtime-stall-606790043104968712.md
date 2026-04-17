# Bug Report: Distributed runtime stalls after loop state reset

## ID
- Execution ID: 606790043104968712
- Date observed: 2026-04-16 local / 2026-04-17 UTC
- Environment: local kind on Colima (arm64)

## Summary
A distributed playbook execution starts and progresses through initial steps, then stops making workflow progress while remaining RUNNING indefinitely.

The execution appears to stall immediately after the engine logs:
- "Reset stale distributed state for new invocation of fetch_assessments"

After that point:
- no new non-checkpointer events are emitted,
- worker pods remain healthy and keep heartbeating,
- NATS command consumer shows no pending or unprocessed messages,
- execution status remains RUNNING with end_time NULL.

## Impact
- Long-running or looping distributed workflows can hang without terminal success/failure.
- User-visible state suggests active execution, but functional progress has stopped.

## Reproduction
1. Bring up local distributed stack (server + worker) in kind.
2. Register credentials and playbooks.
3. Execute:
   - noetl exec catalog://tests/fixtures/playbooks/pft_flow_test/test_pft_flow@1 -r distributed --json
4. Poll status:
   - noetl --server-url http://localhost:8082 status 606790043104968712 --json

## Expected
Execution continues through subsequent loop iterations/facilities and eventually reaches COMPLETED or FAILED with a terminal event trail.

## Actual
Execution remains RUNNING and pinned at load_patients_for_assessments with no further non-checkpointer events.

## Key Evidence
Bundle directory:
- sync/issues/2026-04-16-pft-distributed-stall-606790043104968712

Primary artifacts:
- status snapshot: sync/issues/2026-04-16-pft-distributed-stall-606790043104968712/status_snapshot.json
- execution row: sync/issues/2026-04-16-pft-distributed-stall-606790043104968712/execution_row.json
- all events: sync/issues/2026-04-16-pft-distributed-stall-606790043104968712/events_all.json
- non-checkpointer events: sync/issues/2026-04-16-pft-distributed-stall-606790043104968712/events_non_checkpointer.json
- event liveness probe: sync/issues/2026-04-16-pft-distributed-stall-606790043104968712/event_liveness_probe.json
- server focused extract: sync/issues/2026-04-16-pft-distributed-stall-606790043104968712/noetl-server-focused-extract.log
- worker focused extracts:
  - sync/issues/2026-04-16-pft-distributed-stall-606790043104968712/noetl-worker-5555c8686c-4nbgb.tail3000.focused.log
  - sync/issues/2026-04-16-pft-distributed-stall-606790043104968712/noetl-worker-5555c8686c-xtg77.tail3000.focused.log
  - sync/issues/2026-04-16-pft-distributed-stall-606790043104968712/noetl-worker-5555c8686c-zccbx.tail3000.focused.log
- NATS state:
  - sync/issues/2026-04-16-pft-distributed-stall-606790043104968712/nats_stream_info_NOETL_COMMANDS.txt
  - sync/issues/2026-04-16-pft-distributed-stall-606790043104968712/nats_consumer_list_NOETL_COMMANDS.txt
  - sync/issues/2026-04-16-pft-distributed-stall-606790043104968712/nats_consumer_info_noetl_worker_pool.txt

## Timeline (UTC)
- 05:03:29.993930: playbook.initialized
- 05:03:30-05:03:35: start -> load_next_facility -> setup_facility_work -> load_patients_for_assessments -> claim_patients_for_assessments -> fetch_assessments pipeline progresses
- 05:03:34.xxx: repeated warning in server logs:
  - "Failed to enumerate loop iteration state keys in NATS K/V ... nats: no keys found"
- 05:03:35.984298: server logs
  - "[LOOP] Reset stale distributed state for new invocation of fetch_assessments (completed=100 scheduled=100 size=100 ...)"
- 05:03:36.019071: last non-checkpointer event (from event_liveness_probe)
- 05:09:33.019303: checkpoints still being committed (latest event)
- 05:09:33.040617: execution row still RUNNING, end_time NULL

## Additional Observations
- Worker pods are healthy and continue heartbeat/registration logging.
- NATS NOETL_COMMANDS stream/consumer show no outstanding backlog at capture time:
  - Outstanding Acks: 0
  - Unprocessed Messages: 0
- This indicates the system may be logically stuck in loop/orchestrator state rather than blocked on message transport.

## Suspected Area
- Distributed loop state management around fetch_assessments task_sequence transition, especially stale-state reset and subsequent scheduling path.
- Potential interaction with NATS K/V loop iteration payload lookup failures.

## Minimal Queries Used For Verification
- Execution row:
  - SELECT execution_id, status, start_time, end_time, updated_at, last_event_type, last_node_name FROM noetl.execution WHERE execution_id='606790043104968712';
- Liveness probe:
  - SELECT max(created_at) AS latest_event, max(created_at) FILTER (WHERE node_name <> 'checkpointer') AS latest_non_checkpointer FROM noetl.event WHERE execution_id='606790043104968712';

## Suggested Next Debug Steps
1. Add temporary instrumentation around distributed loop reset path to log post-reset scheduled iteration IDs and enqueue outcomes.
2. Log/fail hard when loop iteration K/V key enumeration returns no keys in a context where keys are expected.
3. Verify whether new fetch_assessments commands are generated after reset and whether their completion contributes to loop state counters.
4. Add an execution watchdog condition: RUNNING with only checkpointer events for >N seconds should emit a stall diagnostic event.
