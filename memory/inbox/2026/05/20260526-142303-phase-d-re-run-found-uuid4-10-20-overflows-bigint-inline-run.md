# Phase D re-run found uuid4 % 10**20 overflows bigint; inline runner result also degenerate
- Timestamp: 2026-05-26T14:23:03Z
- Author: Kadyapam
- Tags: noetl,inline-execution,phase-d,round-b,bug,uuid4,bigint-overflow,pr-612

## Summary
Phase D re-run after PR #613 merged (helm rev 167, image inline-runner-v2-20260526070157 from v2.102.1, NOETL_INLINE_TRIVIAL_CHILDREN=enforce). Discovery 1: localhost:8082 was the kind-noetl context, NOT GKE — all prior 'live smoke' runs were on the local kind cluster, not GKE. Worked around by port-forwarding to GKE noetl-server (svc/noetl 18082:8082), registering vertex-ai-stub (catalog_id 635336388015031156) + tests/inline_runner_phase_d_smoke (635336389659198325) into GKE catalog, and re-running smoke. Parent execution 635336426401301366: SUCCESS at the detector level — meta.inline_decision.inline=True, all tool kinds correctly identified (python, noop), mode=allow_list. The 3 parent terminal events (command.completed, step.exit, call.done) carry meta.inline_mode=worker AND meta.inlined_in_parent. Runner FIRED. But two real defects surfaced: (1) child_execution_id is 20 digits (6.9e19), exceeding PostgreSQL bigint max (9.2e18). API call to /api/executions/<child>/events returns 500: 'value out of range for type bigint'. Some runner-emitted events ended up in the parent stream (3 with inline_mode=worker) but the child stream is not retrievable. (2) parent call.done result.context.data is just {status: ok} instead of vertex-ai-stub's actual canned diagnosis payload. Likely consequence of Bug 1: runner couldn't persist child state due to overflow → result extraction returns degenerate envelope. Fix for Bug 1: change uuid.uuid4().int % (10**20) to % (10**18) at noetl/core/workflow/playbook/inline_runner.py:114 — keeps 60 bits entropy, collision probability ~5e-37. Bug 2 may auto-resolve after Bug 1; needs verification. Worker reverted to dry_run, port-forward killed. Next: open PR with the modulus fix, re-run Phase D, then decide if Bug 2 is separate.

## Actions
-

## Repos
-

## Related
-
