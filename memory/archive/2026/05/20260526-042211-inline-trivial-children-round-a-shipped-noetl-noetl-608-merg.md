# Inline trivial children Round A shipped: noetl/noetl#608 merged
- Timestamp: 2026-05-26T04:22:11Z
- Author: Kadyapam
- Tags: noetl,inline-execution,round-a,closed,pr608

## Summary
PR #608 'feat(inline-execution): Round A detector + dry-run observability' merged. Pointer bumps: repos/noetl 019a9457 -> fbc7716d (merge commit; semantic-release release tag will follow as a small bump). repos/noetl-wiki 3900e2c -> db4900fe (the deferred Round A wiki page now matches merged code). Round A scope shipped: new pure detector module noetl/core/workflow/playbook/inline_execution.py with InlineDecision (inline/reasons/depth/mode); hybrid detection (metadata.inline_when_safe: true + allow-list automation/agents/mcp/*); predicates per round-01 design (max_steps=3, max_depth=3, framework: noetl, tool.kind in {python, mcp, noop}, no callbacks/async/cursor/parallel/finalizers/nested-agent/nested-playbook, tenant/org match); dry-run wiring in noetl/tools/agent/executor.py with three modes (off default / dry_run / enforce-errors-Round-B-not-implemented); meta.inline_decision attached to parent agent result; DEBUG-only logging per logging hygiene rule. 45 tests passed (24 detector predicates + agent executor tests for all three modes). Wiki page live at https://github.com/noetl/noetl/wiki/inline_execution. Dispatch path unchanged — every nested playbook still goes through /api/execute and NATS as today. Thread 2026-05-26-noetl-inline-trivial-children remains active because Round B (actual inline execution path) is the natural follow-up; wait phrase 'proceed with inline implementation' from the original round-01 prompt would unlock it. Round B touches noetl/core/dsl/engine/executor/lifecycle.py, noetl/server/api/core/execution.py + events.py + batch.py, noetl/worker/nats_worker.py dispatch + cancellation + scrub, replay/projector readers, plus parity tests — codex-sized multi-round work. Architectural followup also queued (no handoff opened): noetl-platform-combine-step-boundary-events.

## Actions
-

## Repos
-

## Related
-
