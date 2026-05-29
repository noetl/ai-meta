# Round-2 verification: terminal-event fast path is sound but not the hot zone
- Timestamp: 2026-05-29T18:23:31Z
- Author: Kadyapam
- Tags: perf,batch,issue-29,round-2-verified

## Summary
PR #630 merged (commit 6e147d6c, release 2.103.1). Deployed image terminal-fast-20260529181229 on GKE Helm rev 182. After-rollout sample: cg=0 max dropped 1261ms -> 395ms but p50/p90 did NOT collapse, and logs show ZERO hits on 'already completed; skipping orchestration' branch. The dominant cg=0 tail is NOT the terminal-event re-entry case — it's the main-orchestration path where state.completed=False but commands=[]. Round-3 target: deeper instrumentation breaking engine_total_ms into save_state_ms / persist_event_compat_ms / orchestrate_ms. Comment posted to noetl/ai-meta#29 (stays open). The Round-2 patch is safe and unit-tested; just not the bottleneck I thought.

## Actions
-

## Repos
-

## Related
-
