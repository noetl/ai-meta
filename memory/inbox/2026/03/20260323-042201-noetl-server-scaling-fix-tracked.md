# NoETL server scaling fix tracked
- Timestamp: 2026-03-23T04:22:01Z
- Author: Kadyapam
- Tags: noetl,server-scaling,payload-refs,issue-296,pr-297,AHM-4332

## Summary
Created noetl/noetl issue #296, PR #297, and Jira AHM-4332 for the server control-plane scaling fix. The change introduces runtime leases for singleton loops, unique server instance runtime identities, command context refs, and oversized event-field refs to keep the control plane bounded under horizontal scale.

## Actions
-

## Repos
-

## Related
-
