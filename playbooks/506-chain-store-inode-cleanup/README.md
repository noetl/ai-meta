# Chain-store inode exhaustion on the prod server's `/data` (noetl/ai-meta#506)

**Status: EXECUTED 2026-11-03** (owner-authorized), Steps B–D. Step A, the PVC expansion, was not needed and was not done.

## Result (2026-11-03, 03:41–03:59Z)

| | before | after |
|---|---|---|
| `/data` inodes used | 601,621 (92%) | **123,473 (19%)** |
| `/data` bytes | 3.2G (33%) | 1.3G (14%) |
| chain partitions | 3,587 | 714 |

- **Selection:** `select_candidates.py 7` found 2,874 partitions last written 7 or more days ago. The status API confirmed every one finished, with 0 skipped. Expected reclaim was 478,148.
- **Deletion:** `delete_batches.py candidates.txt 7 10 200` ran 16 batches, a canary of 10 then 200 each. Every batch freed **exactly** its predicted `2·events+6`, and no id dropped out on re-check.
- **After:** `/health` ok, 0 restarts, no ERROR lines. Of the `noetl_chain_populate_total` counters, only `extended` moved (415 → 426, normal traffic).
- **Untouched:** `noetl.event` and Postgres.
- **The driver was rehearsed first** on a throwaway kind pod with dummy partitions. The rehearsal covered exact accounting, the young, no-`cov` and absent-id skips, and both stop paths (inode shortfall, failure counter moved).

**Runway after the cleanup:** at about 17.5k inodes/day, 19% reaches the 80% alert in about 3 weeks. Re-run Steps B–D weekly until server ≥ v3.148.0 runs with `NOETL_CHAIN_RETENTION_HOURS` set (noetl/server#549, default OFF, not yet deployed on prod).

## The problem in one paragraph

`/data` on `noetl-server-rust-embedded-0` (PVC `ehdb-embedded-noetl-server-rust-embedded-0`, 10Gi `standard-rwo`, ext4) is at **92% of its inodes and 33% of its bytes**. The readings are 600,647 of 655,360 inodes at 2026-11-03 02:36Z, and `kubelet_volume_stats_inodes_used` read 0.917. Over the last 7 days it grew about 17.5k inodes/day (`kubelet_volume_stats_inodes_used`, daily at 02:00Z: 478,680 on 10-27 → 600,985 on 11-03). That leaves about **3 days, so exhaustion lands around 2026-11-06**. Nearly all of it is the chain store at `/data/ehdb-chain`, which keeps **2 files per event + 6 inodes per execution**. That formula predicts 599,080 inodes against 600,647 in use. Nothing ever deletes a partition. The byte alert reads 0.33 and is quiet.

## What was established (2026-11-03)

### 1. Expanding the volume DOES add inodes (kind, empirical)

ext4 fixes the inode **ratio** at mkfs time (one per 16 KiB by default), not the inode **count**. `resize2fs` adds block groups, and each new group arrives with its own 8,192 inodes.

| test | before | after |
|---|---|---|
| offline, `mkfs.ext4` default, 10G → 20G → 40G | 655,360 (= prod's exact count) | 1,310,720 → 2,621,440 |
| online (loop device mounted, 2,000 files present), 1G → 2G | 65,536 | 131,072, all 2,000 files kept |

Expanding the PVC to 20Gi gives 1,310,720 inodes, which is about 38 more days at the current rate. That is a stopgap. It does not fix anything, because the store never shrinks.

### 2. Deleting a chain partition is safe, and it rebuilds from `noetl.event` (code + kind)

**Code (server v3.147.0, ehdb v0.13.4):**
- The **only writer** is `LogSourcedChainSource::chain_for` (`src/handlers/chain_populate.rs`). It reads the execution's events from `noetl.event`, runs `populate_from_log`, and then answers from the store under the same lock hold. Emit-time writes are deliberately unwired, and `the_chain_populator_is_NOT_wired_to_the_emit_chokepoint` enforces that.
- On an **empty** partition, `populate_from_log` appends the whole log, writes `cov` and then `wm`, and returns `InSync`. A missing partition is therefore a full repopulate, not an error.
- The **only caller** is the reconcile poller, and it walks `orch_cache.active_executions()`. A terminal event evicts the execution from that cache, so a finished execution's partition is **never read again** unless the execution comes back into the cache.
- A partial or raced partition fails the `wm`/`cov` length checks in `chain_if_authoritative`. The read then returns `None`, and the caller runs today's Postgres path. Every failure direction falls back to Postgres.
- State replay (`rebuild_state_chain_walk`) walks Postgres (`fetch_chain_node(pool, …)`) and never touches this store.

**kind, v3.147.0 with prod's chain flags (`NOETL_CHAIN_ADVANCE=true`, `NOETL_CHAIN_POPULATE=true`, `NOETL_CHAIN_SOURCE=chain`):**

| test | result |
|---|---|
| T1: delete a FINISHED execution's partition (20 events) | 46 inodes freed (= 2·20+6). Not recreated over 2+ min. `/api/executions/{id}` and `/status` byte-identical before and after. |
| T2: delete an ACTIVE run's partition mid-run (`tests/loop_335_slow`, 10 events stored) | Recreated about 6 s later by the next reconcile tick, holding 15 events (it caught up). The run finished `COMPLETED`. |
| T2 control: the same playbook started at the same moment, untouched | `COMPLETED`, 39 log events, partition 30/30, 66 files. **Identical** to T2. |
| T2 order check | Rebuilt partition = the first 30 `noetl.event` ids in order. The 10 deleted entries = the first 10. |
| counters during the test | `diverged`, `guarded_read_refused`, `populate_failed`, `stale_log*` all stayed 0. |

### 3. Prod candidate set (read-only, measured)

| last write to the partition (`wm` mtime) | partitions | inodes |
|---|---|---|
| ≥ 1 day | 3,504 | 582,378 |
| ≥ 3 days | 3,212 | 543,168 |
| **≥ 7 days (recommended)** | **2,871** | **477,530** |

A random sample of 100 from the ≥7d set came back **100/100 terminal** (99 COMPLETED, 1 CANCELLED). Four partitions have `wm` but no `cov`. They date from about Sep 30, probably predate the coverage file, and are excluded anyway (see below).

The expected result is `/data` going from about 92% to **about 19%** of inodes.

## How this interacts with the rest of #506

- **#504 (a worker's result lost across a server restart):** that is a *non-terminal* execution waiting on a straggler, so the terminal filter excludes it. If a late event ever brings a finished execution back into the active cache, the next tick rebuilds the partition from the log, which T2 demonstrated. The 7-day settle window is several orders of magnitude longer than any step's lifetime, so no straggler can be in flight for these. No #504 fix needs to land first.
- **The stuck archive floor and the bloom-false-match hypothesis (RFC phase 1):** these are **independent**. The floor governs `/data/ehdb-embedded`, the event-log parts, which is bytes and about 1.5k inodes. It has no effect on the chain store. Moving the floor frees bytes, not inodes, and deleting chain partitions frees inodes, not event-log bytes.
- **`noetl.event` is untouched.** It stays append-only and is never purged. The chain store is a derived cache of it.

## ⛔ Procedure (needs the owner's go at each ⛔)

All commands name `--context noetl-prod` explicitly. Do **not** run a recursive `find` over `/data/ehdb-chain`. Six of them took over 3 minutes on 2026-11-03.

### Step 0: pre-checks (read-only)

```bash
kubectl --context noetl-prod -n noetl exec noetl-server-rust-embedded-0 -- df -i /data
kubectl --context noetl-prod get --raw /api/v1/namespaces/noetl/pods/noetl-server-rust-embedded-0:8082/proxy/metrics \
  | grep -E '^noetl_server_build_info|^noetl_chain_populate_total' > before.prom
```

Go/no-go: build ≥ v3.146.1 (the #503 scoped walk), and 1/1 Ready.

### ⛔ Step A, stopgap: expand the PVC 10Gi → 20Gi (recommended first, lowest risk)

```bash
kubectl --context noetl-prod -n noetl patch pvc ehdb-embedded-noetl-server-rust-embedded-0 \
  -p '{"spec":{"resources":{"requests":{"storage":"20Gi"}}}}'
kubectl --context noetl-prod -n noetl get pvc ehdb-embedded-noetl-server-rust-embedded-0 -o jsonpath='{.status.capacity.storage} {.status.conditions}'
kubectl --context noetl-prod -n noetl exec noetl-server-rust-embedded-0 -- df -i /data   # expect ~1,310,720
```

- Online: `standard-rwo` has `allowVolumeExpansion: true`, and the PD CSI driver runs `resize2fs` on the mounted filesystem with no restart.
- **Irreversible:** a PD cannot shrink. The cost is about +$1/month for 10Gi of pd-balanced.
- ⚠ Drift this creates: the STS `volumeClaimTemplates` still say 10Gi and are immutable. Record the 20Gi in the ops manifest comment, so a re-created PVC (DR, new region) doesn't silently come back at 10Gi.

### Step B, select candidates (read-only, ~15 min at 3 req/s)

```bash
python3 playbooks/506-chain-store-inode-cleanup/select_candidates.py 7 .
```

This writes `candidates.txt` and `skipped.json`. Go/no-go: the `skipped` count is explained, and `expected_inode_reclaim` is about 470k.

### ⛔ Step C, canary: delete 10

```bash
head -10 candidates.txt > batch.txt
kubectl --context noetl-prod -n noetl exec -i noetl-server-rust-embedded-0 -- sh -c '
  cd /data/ehdb-chain/chain || exit 1
  while read id; do
    case "$id" in ""|*[!0-9]*) echo "SKIP bad id: $id"; continue;; esac
    [ -d "$id" ] || { echo "absent $id"; continue; }
    rm -rf -- "./$id" && echo "deleted $id"
  done' < batch.txt
kubectl --context noetl-prod -n noetl exec noetl-server-rust-embedded-0 -- df -i /data
```

Pass condition:
- the inode delta equals Σ(2·events+6) for the batch;
- `noetl_chain_populate_total{outcome=~"diverged|guarded_read_refused|populate_failed|stale_log_unresolved"}` unchanged against `before.prom`;
- `/health` ok;
- no new ERROR lines in the server log.

The id guard accepts digits only, and `cd … || exit 1` means a bad path can't fall through to a delete somewhere else.

### ⛔ Step D, the rest, in batches of 200 with a pause

`delete_batches.py` runs Steps C and D with every check built in, and is what ran on 2026-11-03:

```bash
python3 playbooks/506-chain-store-inode-cleanup/delete_batches.py candidates.txt 7 10 200
```

The manual loop below is the same logic, kept for reading.

```bash
tail -n +11 candidates.txt | split -l 200 - batch.
for b in batch.*; do
  # same loop as Step C, with "< $b", then:
  sleep 5
  kubectl --context noetl-prod -n noetl exec noetl-server-rust-embedded-0 -- df -i /data | tail -1
done
```

Stop condition: any pass condition from Step C fails, or the server's p99 or `/health` regresses. Unlinking about 470k small files on pd-balanced is real I/O, which is why it goes in batches.

**Rollback:** there is nothing to restore, because each partition rebuilds from `noetl.event` on its next read (T2). An optional backup before Step C is `kubectl exec … tar czf - -C /data/ehdb-chain/chain <ids>`. That reads every file once, the same load as a `find`. The content is derived, so the backup isn't recommended.

## The permanent fix (not in this runbook)

Without a code change the store refills at about 17k inodes/day. After Step D the steady state is 7 days × 17k, about 120k inodes, roughly 18% of 655k. Until the server deletes a finished partition itself, re-run Steps B–D weekly. The code fix is to delete the partition after the terminal eviction plus a settle window, or a periodic sweeper inside the server. That's tracked from #506.
