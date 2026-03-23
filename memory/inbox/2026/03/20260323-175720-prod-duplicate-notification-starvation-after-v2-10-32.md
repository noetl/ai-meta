# prod duplicate notification starvation after v2.10.32
- Timestamp: 2026-03-23T17:57:20Z
- Author: Kadyapam
- Tags: noetl,prod,worker,nats,starvation

## Summary
On prod v2.10.32, #312 is live but stalled-start repro remains because duplicate notifications still spend 15-40s in worker claim_and_fetch before active_claim ACK. Linked issue #313 and PR #314 add worker-local recent command_id short-circuit.

## Actions
-

## Repos
-

## Related
-
