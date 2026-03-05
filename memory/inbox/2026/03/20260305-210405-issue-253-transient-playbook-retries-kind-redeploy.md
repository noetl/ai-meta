# Issue 253 transient playbook retries + kind redeploy
- Timestamp: 2026-03-05T21:04:05Z
- Author: Kadyapam
- Tags: noetl,worker,retry,ops,kind,issue-253

## Summary
Implemented transient HTTP retry logic (ReadError, RemoteProtocolError, ConnectError) in noetl worker sub-playbook execution path for spawn and status polling; added worker tests; committed in repos/noetl at 6fbf00ef; redeployed to local kind via repos/ops noetl playbook (runtime local, action=redeploy); cluster now running local/noetl:2026-03-05-12-58 with noetl-server 1/1 and noetl-worker 3/3 ready.

## Actions
-

## Repos
-

## Related
-
