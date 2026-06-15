# Cursor/claim loop mode live in Rust orchestrator (#100)
- Timestamp: 2026-06-15T10:25:05Z
- Author: Kadyapam
- Tags: cursor-loop,orchestrator,pft,issue-100,output-namespace,postgres,kind,gke

## Summary
mode: cursor (loop.cursor + spec.frame) implemented in the Rust orchestrator (server v3.8.0, server#196). Orchestrator-driven (honors execution-model.md, NOT the Python long-lived frame-leasing worker): entry emits step.enter(__cursor_loop marker)+claim frame 0; on claim command.completed, 0 rows->DRAIN (mark step Completed + __cursor_drained step.exit -> transition routes next arcs with event.name=loop.done), K rows->fan out body per claimed row bounded by frame.row_concurrency; frame done->re-claim. Claim runs as a normal postgres tool command; RETURNING rows->iter.<iterator>; __frame_max_rows injected for the claim LIMIT; stale-reclaim is the playbook claim SQL's own reclaim_stale CTE (no server frame/lease table). Key: claim rows come from the call.done event not command.completed; StepInfo.is_cursor guards apply_event so claim/body completions don't complete the step; reconstruct_cursor_frames resets on each step.enter for loop-back re-entry. Also fixed 3 PFT-parity gaps: output namespace in arc when:/step set: (server#196), cursor re-entry frame reset (server#196), and postgres -- comment splitter swallowing statements after an apostrophe-in-comment (tools#66 v3.10.1, worker#88 bump). Validated end-to-end kind+GKE: test_pft_flow_v2 all_passed:true, GKE 20/20 + kind 5/5 per data type, against the throttling/error-injecting paginated-api (proves handles errors+loops). GKE dev image tags: server cursor-100-v3, worker cursor-100. paginated-api also deployable to kind (test-server ns, source repos/e2e/fixtures/servers/paginated_api.py) for fast full-PFT iteration. Pointers server 1418a93/tools 454ab6e/worker e4b4a64.

## Actions
-

## Repos
-

## Related
-
