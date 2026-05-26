# Platform step-overhead: case-action emit batching shipped as noetl/noetl#607 (small win)
- Timestamp: 2026-05-26T03:45:47Z
- Author: Kadyapam
- Tags: noetl,worker,perf,batching,pr607

## Summary
Drove the noetl-platform-step-overhead-reduction follow-up directly (no codex handoff). Surveyed the worker per-step event-emission landscape: initial batch (2 events) takes ~192ms, terminal batch (3 events via _emit_terminal_event_batch) takes similar — both already batched via /api/events/batch which server-side uses cursor.executemany in one Postgres transaction. The bottleneck was the case-action routing branch in nats_worker.py:2188-2282 which still fired 4 sequential individual _emit_event HTTP roundtrips (case.evaluated + call.done|call.error + step.exit + command.completed) for 200-400ms per case-evaluated step. PR #607 collapses those into a single _emit_batch_events call preserving all event names/payloads/meta/actionable flags. Per-step saving: ~150-300ms on case-action steps. Test: code-shape assertion test_case_action_handler_uses_a_single_batched_emit pins the structural invariant; 8 tests in test_worker_batch_emit.py pass. No wiki update needed — internal worker refactor with no public-surface change (Rule 1b applies to public surface changes). Two larger architectural opportunities NOT in this PR — flagged in the PR body for a follow-up handoff: (1) inline trivial nested playbook execution (tool: agent framework: noetl with small children adds 500-1500ms; needs design — heuristic for 'trivial' or explicit spec.inline: true); (2) combine command.completed + step.exit + call.done into a single boundary event (touches event-log consumers across the codebase + replay semantics). Both are codex-handoff-sized; not driven directly. PR #607 awaiting review, marked draft.

## Actions
-

## Repos
-

## Related
-
