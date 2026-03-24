# NoETL task sequence continuation state fix PR318
- Timestamp: 2026-03-24T03:57:49Z
- Author: Kadyapam
- Tags: noetl,prod,task-sequence,fetch-medications,pr318

## Summary
Prod tracing split the medication-path follow-up from stuck execution cleanup. Root cause candidate: task_sequence call.done returned before saving loop state and before recording emitted commands in issued_steps, which can stale continuation bookkeeping. Opened noetl/noetl#318 and cancelled churn-heavy execution 589251756484198578 during debugging.

## Actions
-

## Repos
-

## Related
-
