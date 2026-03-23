# NoETL v2.10.31 prod validation still stalls initial start command
- Timestamp: 2026-03-23T17:15:13Z
- Author: Kadyapam
- Tags: noetl,prod,nats,validation,stalled-start

## Summary
After deploying noetl v2.10.31 from PR #310 to bhs prod, direct validation against server-noetl-655f48ccdb-4hv2g reproduced execution 589035483489895087 stuck with only playbook.initialized, workflow.initialized, and command.issued(start). The new fast recovery hook logged a re-publish after 20s, but no command.claimed event appeared and worker logs never showed the execution. NATS NOETL_COMMANDS consumer state showed substantial backlog (num_pending=209, num_ack_pending=12), so current suspicion shifted from pure publish failure toward consumer backlog or worker delivery pressure.

## Actions
-

## Repos
-

## Related
-
