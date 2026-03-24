# Active-claim duplicate notifications can starve fresh commands under backlog
- Timestamp: 2026-03-23T17:30:46Z
- Author: Kadyapam
- Tags: noetl,prod,worker,nats,active-claim,backlog

## Summary
Prod validation of noetl v2.10.31 showed the fast command publish recovery from PR #310 firing, but execution 589035483489895087 still stalled at command.issued(start). A deeper read of worker logs and code showed duplicate active_claim notifications spending 30-50 seconds before delayed NAK, which can occupy worker inflight slots and starve newer commands when NATS backlog is high (num_pending=209, num_ack_pending=12). Opened issue noetl/noetl#311 and PR #312 to ACK duplicate active_claim notifications immediately while preserving retry for unknown 409 conflicts.

## Actions
-

## Repos
-

## Related
-
