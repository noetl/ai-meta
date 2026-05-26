# Bug B fix PR #615 — runner mirrors dispatched-path boundary-step filter
- Timestamp: 2026-05-26T15:39:10Z
- Author: Kadyapam
- Tags: noetl,inline-execution,phase-d,pr-615,result-envelope,bug-fix

## Summary
Round B Phase D Bug B fix open as PR #615 on branch kadyapam/inline-runner-terminal-result-semantics (commit 11bceb02). Adds _BOUNDARY_STEP_NAMES={start,end,''} in noetl/core/workflow/playbook/inline_runner.py; tracks last_meaningful_result alongside last_result; InlineResult.data = last_meaningful_result if not None else last_result. Mirrors the dispatched path's _fetch_sub_execution_terminal_result _BOUNDARY_NODE_NAMES filter exactly. 3 new regression tests: noop-end-skip, all-boundary-fallback, start-boundary-skip. 56/56 tests pass. After merge: bump pointer, rebuild image (inline-runner-v4-*), redeploy, enforce, re-run smoke. Expect parent call.done result.context.data to carry vertex-ai-stub's canned diagnosis (category, confidence, root_cause, etc.) NOT the noop end's {status:ok}. Then spot-check parent-cancel cascade.

## Actions
-

## Repos
-

## Related
-
