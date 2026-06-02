# noetl-server: Arrow encoder + workflow.completed fixes (#36 + #37 closed)
- Timestamp: 2026-06-02T00:21:04Z
- Author: Kadyapam
- Tags: noetl-server,arrow-ipc,outbox,workflow-completion,terminal-step,batch-projector,observability,kind-validation,#36,#37,#35,#34

## Summary
Three PRs landed closing two server-side bugs: noetl/noetl#650 + #651 fixed Arrow type-inference choke in events.batch projector (cross-row + nested-payload mixed types via _build_safe_arrow_table fallback in arrow_ipc.py; outbox tolerates encoding failure with payload_codec=json + NULL payload_bytes since JSONB is source-of-truth). noetl/noetl#649 fixed engine not emitting workflow.completed for terminal steps named anything other than 'end' (_count_durable_pending_commands now excludes the in-flight triggering command; status endpoint generalises node_name==end check to step.next is None / pending_count==0). The logger.exception traceback added at batch.py:626 paid off immediately — surfaced the #651 follow-up site in one run. Kind-validated end-to-end with PIN_RUST_WORKER=0 (Python worker path that originally exposed both bugs): full small_select → big_select → done lifecycle, workflow.completed + playbook.completed fire ~50ms after done.command.completed, status endpoint reports completed=True inferred=False. Pointer bumped in ai-meta@17f9c5f. Validation rig refresh from earlier in session (noetl/ops#135) closes #35 — restored worker pinning + fixed SQL filter shape from worker_id LIKE to execution_id = :exec_id + dropped legacy 'payload' column reference.

## Actions
-

## Repos
-

## Related
-
