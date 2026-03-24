# stuck execution reaper opened after prod cleanup unblocked queue
- Timestamp: 2026-03-24T01:30:37Z
- Author: Kadyapam
- Tags: noetl,prod,stuck-executions,cleanup,github-issue,pr-316

## Summary
In bhs-analytics-prod on 2026-03-23, cancelling 10 stale nonterminal executions immediately unblocked fresh execution 589283664886759660. Opened noetl/noetl issue #315 and PR #316 for a leased stuck execution reaper that auto-cancels executions with no terminal event and no event progress past a configurable inactivity window.

## Actions
-

## Repos
-

## Related
-
