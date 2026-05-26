# Case-action emit batching shipped: noetl/noetl#607 merged; bumped to v2.100.10 (covers #606 + #607)
- Timestamp: 2026-05-26T03:50:18Z
- Author: Kadyapam
- Tags: noetl,worker,perf,batching,closed,pr607,v2.100.10

## Summary
PR #607 'perf(worker): collapse case-action handler emits into single batch' merged. semantic-release published v2.100.9 (from #606 listings fix) and v2.100.10 (from #607) in the same window. repos/noetl bumped 3b03ba95 -> 019a9457 (v2.100.10 release tag, includes both #606 and #607). Case-action routing branch in nats_worker.py:2188-2282 now uses a single _emit_batch_events call instead of 4 sequential individual _emit_event roundtrips: saves ~150-300ms per case-evaluated step. Test: code-shape assertion test_case_action_handler_uses_a_single_batched_emit pins the structural invariant; 8 tests in test_worker_batch_emit.py pass. No wiki update needed — internal worker refactor with no public-surface change (event names, payloads, ordering preserved). One active thread remaining: 2026-05-26-noetl-inline-trivial-children (audit-first with Phase C gated on wait phrase, awaiting codex dispatch). Architectural followup still queued (no handoff opened): noetl-platform-combine-step-boundary-events.

## Actions
-

## Repos
-

## Related
-
