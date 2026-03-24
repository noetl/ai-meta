# prod v2.10.33 still stalls fresh start commands
- Timestamp: 2026-03-24T00:16:41Z
- Author: Kadyapam
- Tags: noetl,prod,nats,worker,starvation,v2.10.33

## Summary
v2.10.33 rollout succeeded, but fresh execution 589249806132838459 still stalled at command.issued after 90s. Worker-local duplicate short-circuit from #314 is live, yet start starvation remains under older backlog/reclaim churn.

## Actions
-

## Repos
-

## Related
-
