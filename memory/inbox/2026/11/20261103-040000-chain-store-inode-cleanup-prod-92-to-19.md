# Chain-store inode cleanup on prod: /data 92% -> 19% of inodes; retention sweeper shipped OFF
- Timestamp: 2026-11-03T04:00:00Z
- Author: kadyapam
- Tags: ehdb,chain-store,inodes,prod,server,monitoring,rfc-506

## Summary
Prod /data (PVC ehdb-embedded-noetl-server-rust-embedded-0, 10Gi ext4, 655,360 inodes) was at 92% of inodes and 33% of bytes. Exhaustion was projected for ~2026-11-06, and nothing alerted. The cause: the chain store keeps 2 files per event + 6 inodes per execution, and nothing ever deleted a partition. The formula predicted 599,080 against 600,647 in use.

Done 2026-11-03, owner-authorized:
- Inode alerts merged and applied: noetl/ops#359 (80% of inodes; predict_linear 7d). The live-vs-committed diff showed only my 3 changes; 2 created, 24 updated.
- Kind (v3.147.0, prod chain flags):
  - Deleting an ACTIVE run's partition: it rebuilt on the next tick and matched an untouched control.
  - Deleting a FINISHED one: freed exactly 2e+6 inodes, never recreated, API reads byte-identical.
  - ext4 resize DOES add inodes (10G->20G = 655,360->1,310,720, online too).
- Prod cleanup with playbooks/506-chain-store-inode-cleanup (select_candidates.py + delete_batches.py):
  - 2,874 partitions, last written >=7d ago, all confirmed terminal by the status API, 0 skipped.
  - Canary of 10, then batches of 200. Every batch freed exactly its predicted 2e+6.
  - Result: used 601,621 -> 123,473 (92% -> 19%); bytes 3.2G -> 1.3G.
  - /health ok, 0 restarts, no ERROR lines; chain_populate failure counters unchanged.
  - noetl.event and Postgres untouched.
- Server v3.148.0 (noetl/server#549): the retention sweeper NOETL_CHAIN_RETENTION_HOURS, default OFF.
  - Deletes inactive partitions whose wm is older than the window and that have a cov file; re-checks under the chain-store lock.
  - Kind: finished+backdated was deleted, finished+young kept, active+backdated kept, the active run COMPLETED.
  - NOT deployed or armed on prod: that needs a server roll, held for the owner.

## Actions
- Owner: roll the server to v3.148.0 and set NOETL_CHAIN_RETENTION_HOURS (suggested 168). Until then, re-run the runbook weekly: about 17.5k inodes/day from 19% reaches the 80% alert in ~3 weeks.
- RFC P0b and P2-P5 (archive clock, re-touch, hold classes, fast path) are not started.

## Repos
- noetl/server#549 (v3.148.0), noetl/ops#359, noetl/ai-meta#507 (RFC), #509 (runbook)

## Related
- noetl/ai-meta#506, #504 (worker v6.11.2 outage budget 120s; the 7d window covers it many times over)
