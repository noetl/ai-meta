# Container Tool Callback umbrella #43 CLOSED — feature-complete
- Timestamp: 2026-06-07T04:56:04Z
- Author: Claude
- Tags: container-tool-callback,umbrella-closed,noetl-ai-meta-43,session-summary,k8s-job-callback

## Summary
All four Rust rounds of noetl/ai-meta#43 shipped this session: Round 1 noetl/ops k8s-watcher Deployment + RBAC + shell watcher script (ops@8892043, ops#167), Round 2 noetl/server POST /api/internal/container-callback/{eid}/{step} (v2.48.0, server#141), Round 3 noetl/tools Tool::Container + additive ToolResult.pending_callback marker (v2.21.0, tools#37), Round 5 noetl/e2e kind-val rig with happy-path + OOMKilled fixtures + sum-both-counters assertion (e2e@17de21d, e2e#30). Round 4 (Python parity) parked per Rust-only standing direction. Umbrella closed with citation comment + roadmap board flipped to Done. The chain now ships end-to-end: Tool::Container creates a labeled K8s Job and returns immediately (worker slot frees on create-Job RPC return); noetl-k8s-watcher Deployment observes Job state transitions and POSTs the 6 TerminalState variants (succeeded/failed/failed_image_pull/failed_oom/failed_node_lost/failed_timeout) to the server's container-callback handler; server emits call.done on match or bumps noetl_container_callback_stale_total{state} on stale; kind_validate_container_callback.sh drives the chain with two fixtures + counter-delta assertions. The one remaining follow-up is worker-side adoption of the pending_callback marker (suppressing the worker's own call.done emit when the marker is set) — coordinated change in noetl/worker; harmless during the transition (the watcher's callback is recorded by noetl_container_callback_stale_total which is the migration dashboard signal). Open ai-task umbrellas remaining: #49 (Rust server FastAPI parity port — largely shipped, R5 production cutover is an ops decision), #65 (noetl-tools python script loaders — off-limits per Rust-only direction).

## Actions
-

## Repos
-

## Related
-
