# #205 + #208 combined prod rollout — shastaratech prod, 2026-07-30

Rolling image update on the **live EHDB command bus**.  Not a bus change:
`NOETL_COMMAND_BUS=ehdb` before and after.  NATS untouched — T5 still pending.

Cluster `gke_shastaratech-noetl-prod_us-central1_noetl-prod-autopilot`, ns `noetl`.

## What shipped

| Repo | PR | Merge SHA | Version |
| :- | :- | :- | :- |
| ehdb | [#302](https://github.com/noetl/ehdb/pull/302) writer-restart recovery | `86a24f95841be0d2cf031eba1bcf44c9a627c1d1` | — (engine) |
| server | [#289](https://github.com/noetl/server/pull/289) latency adoption | `c237652c68d22aa007bd2d859002283368cfeb2b` | v3.58.2 |
| server | [#290](https://github.com/noetl/server/pull/290) publish redial retry | `9938d4a8285123382076537ccc42e8203a969c53` | **v3.58.3** |
| worker | [#195](https://github.com/noetl/worker/pull/195) latency adoption | `6422fb9572081d946fbdf4f269cbb2fc3d7ebff0` | v5.81.2 |
| worker | [#196](https://github.com/noetl/worker/pull/196) restart adoption | `ddeb564d385b50f17fa6591aebcbf099458c1721` | **v5.81.3** |

All four ehdb crates in both repos pinned to ehdb `86a24f9`; zero stale
branch-SHA refs (#290 carried `71033b3`, #196 carried `d7a06c2` — both were
#302 *branch* commits, resolved to the merged main SHA).

## Images (Artifact Registry, amd64, deployed by digest)

Cloud Build → AR ([#204](https://github.com/noetl/ai-meta/issues/204)) is still
gated off (repo vars unset, pending SA grants), so GHCR → AR via `crane`.

```
SERVER_IMG=us-central1-docker.pkg.dev/shastaratech-noetl-prod/noetl/server-rust@sha256:b49e67fa0f5577816ae71aa5e7877028aa062f2e5f833b24a4908cd54c4c86a0        # v3.58.3
WORKER_IMG=us-central1-docker.pkg.dev/shastaratech-noetl-prod/noetl/noetl-worker-rust@sha256:b28257e6cdcb4575b9ab562639b2a7f203b5eea9a32951ae464c1fae63b9b384  # v5.81.3
```

## Pre-existing prod defect found on arrival

**User-playbook dispatch had been dead for ~2.4 days.**  writer-0 restarted
`2026-07-28T07:49Z`, ~4.5 h after the user-pool workers started.  Both
`noetl-worker-rust` pods' *last* log line was from that moment —
`EHDB claim connect failed; retrying … Connection refused` — then silence.
That is exactly the #208 wedge.  `noetl-worker-system-pool-shard1` restarted
later (07-29 16:17) so system commands (`scheduled_cleanup`) kept completing,
which masked the outage.

Consequence: a *pre-deploy* latency baseline on the old images was not
obtainable — nothing was being claimed.  The comparison points are the
recorded T4 numbers.

## Results

### Latency (#205 gate) — **PASS**

`command.issued → command.claimed` from `noetl.event`, via
`GET /api/ehdb/executions/{id}/events`.

| Regime | n | p50 | p95 | p99 | notes |
| :- | -: | -: | -: | -: | :- |
| NATS baseline (T4, 07-27) | 90 | 338 ms | 511 ms | 520 ms | the envelope |
| EHDB at T4 (07-27) | — | 285–557 ms | — | ~1040 ms | the T5 concern |
| **EHDB now, unsaturated** | **60** | **138.5 ms** | **156.4 ms** | **181.0 ms** | 20/20 COMPLETED |
| EHDB now, post-restart | 45 | 140.5 ms | 191.6 ms | 208.0 ms | unchanged after restart |
| EHDB now, 90 cmds burst | 90 | 2123 ms | 3701 ms | 3735 ms | **pool queueing, not bus** |

**p50 138.5 ms vs the 338 ms NATS baseline — the bus is now ~2.4× faster than
NATS, and ~2–4× faster than EHDB was at T4.**

The burst row is *not* a bus measurement.  The user pool is pinned at 2
replicas × `WORKER_MAX_CONCURRENT=4` = **8 slots**, and its KEDA ScaledObject
is `paused=true` and still triggers on **nats-jetstream** lag.  90 commands
into 8 slots queues.  See "Open gap" below.

### Writer-restart recovery (#208 gate) — **PASS**

Deleted the writer pod mid-stream under continuous load.

- **38 executions accepted → 38 terminal → 38 COMPLETED, 0 stuck.**
- Commands dispatched: **40 before + 74 after = 114 = 38 × 3 exactly.**
  Zero duplicates, zero loss.
- Redial: writer died `18:18:22`; worker logged
  `EHDB claim_next failed; reconnecting to the claim coordinator … early eof`
  at `18:18:22.056` and retried ~every 250 ms; coordinator up `18:18:24.765`.
  **~2.7 s to recovery.**  The old code produced no such line — it wedged.
- Post-restart dispatch p50 154 ms, max 522 ms.
- `ehdb_feed_shard_committed{shard="0"}` is now exposed (new in #302) and is
  the honest signal; lag reads 0 both caught-up and post-replay.

### Two caveats, reported not glossed

1. **`from_cursor=0 origin="persisted"`.**  The resume took the *durable*
   path (`origin="persisted"`, vs `"fallback_tail"` on first boot), but the
   logged cursor is `0`, and `ehdb_feed_shard_committed` reset 408 → 165
   across the restart.  The counter is evidently segment-relative, not a
   global monotonic offset.  **No replay occurred** — proven by the exact
   114 = 38×3 command arithmetic with zero duplicates.  But the log line
   alone cannot distinguish "resumed" from "replayed from 0", which is
   precisely the signal a runbook would lean on.  Worth a follow-up.
2. **2 × HTTP 500 on `POST /api/execute`** during the writer's absence.  The
   #290 publish redial retry did not span the full pod-restart window.  This
   is fail-closed (the caller is told; no silent loss — every *accepted*
   execution completed), but it is not transparent.

### Open gap for T5

The user pool cannot autoscale on EHDB backlog: its ScaledObject is paused
and its trigger is `nats-jetstream`.  After T5 deletes NATS there would be
**no scaler signal at all** for the user pool.  This needs an EHDB-lag
trigger (`ehdb_feed_shard_lag` on writer `:9102`) before T5.

## Rollback

Prior digests, still on the EHDB bus — a rollback restores the *previous*
images, it does not change the bus:

```bash
CTX=gke_shastaratech-noetl-prod_us-central1_noetl-prod-autopilot
K() { kubectl --context "$CTX" -n noetl "$@"; }

PREV_SERVER=us-central1-docker.pkg.dev/shastaratech-noetl-prod/noetl/server-rust@sha256:5a73f4a5477f9ed2f8cc3bc2a390a4bf30515c90f17ef3bc9884ae4832782f8f       # v3.58.1
PREV_WORKER=us-central1-docker.pkg.dev/shastaratech-noetl-prod/noetl/noetl-worker-rust@sha256:db156fa6e20ce006393f989f29936e5b23fb15cf476719d9439a2cd0844bcab3  # v5.81.1

K set image deploy/noetl-server-rust noetl-server="$PREV_SERVER"
for d in noetl-worker-rust noetl-worker-system-pool noetl-worker-system-pool-shard1 \
         noetl-cmdbus-writer-0 noetl-cmdbus-writer-1; do
  K set image deploy/$d noetl-worker="$PREV_WORKER"
done
```

⚠ Rolling back reinstates the #208 wedge: any claimer older than the writer
stops claiming, silently.  Full bus→NATS rollback remains
`playbooks/194-l1-t4-prod-iac/rollback.sh`.

⚠ **Patch the writer with `--type strategic` (the default), never
`--type merge`.**  A JSON-merge patch replaces the `containers` array
wholesale and wipes the writer's 21 env vars, ports, volumeMount and probes —
the pod then boots as a default worker and dies on
`authorization violation` against NATS.  That happened during this run;
recovery was `kubectl rollout undo --to-revision=10`.

## Deploy order used

server → writer → worker pools.  Claimers come up last, against an
already-running writer.

`terminationGracePeriodSeconds` on writer-0 raised 30 → **90 s** to cover the
SIGTERM seal.  Writer PVC (`noetl-cmdbus-writer-0-data`, premium-rwo 20 Gi)
was already in place, `Recreate` strategy — cursor persistence is real.

## State at hold

- server **v3.58.3**, all worker pools + both writers **v5.81.3**.
- `NOETL_COMMAND_BUS=ehdb` everywhere, `NOETL_COMMAND_SHARD_COUNT=1`.
- #166 state sharding intact (`NOETL_SHARD_COUNT=2`, index 0/1,
  `NOETL_STATE_BUILDER=offserver`, `NOETL_STATE_SHARD_WRITE=true`).
- 6/6 pods Ready, **0 restarts**.
- **NATS untouched** — ns `nats` + ns `nats-supercluster`, 4 d uptime, 0
  restarts.  **T5 NOT performed.**
- Test residue: ~4 orphaned synthetic `hello_world` executions from the
  pre-deploy wedge window (stuck at `command.issued`, never claimed).
  Harmless, consistent with prior rounds.
