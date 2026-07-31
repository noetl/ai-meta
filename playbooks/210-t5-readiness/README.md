# T5-readiness — executed 2026-07-31, shastaratech prod

Makes deleting NATS a decision rather than a gamble: land the held command-bus
stack, deploy it, and give the user pool an autoscaling signal that survives the
deletion. **NATS was not touched.** T5 is still the human's call.

Cluster: `gke_shastaratech-noetl-prod_us-central1_noetl-prod-autopilot`, ns
`noetl`. Bus stayed `NOETL_COMMAND_BUS=ehdb` throughout.

## What shipped

| Repo | Merged | Released |
|---|---|---|
| noetl/ehdb | #303 per-subject lag, #304 resume signal | main `e457249` |
| noetl/server | #291 publish retry 0.5 s → 10 s, #292 ehdb re-pin | **v3.58.4** |
| noetl/worker | #197 writer serves per-pool lag + resume, #198 append-integrity counters | **v5.82.0** → **v5.83.0** |
| noetl/ops | #242 ScaledObject + PodMonitoring, #243 activation, #244 drop NATS trigger | — |

Images reached Artifact Registry by `crane` copy from GHCR, **not** Cloud Build:
the `publish-ar` job fails on every release because the build SA cannot stage
source in the `_cloudbuild` bucket. Tracked as
[#211](https://github.com/noetl/ai-meta/issues/211) — needs an IAM grant, which
agents do not make on this project.

## Prod state after

```
noetl-server-rust                 server-rust@sha256:8fb29a4c…  (v3.58.4)
noetl-worker-rust                 noetl-worker-rust@sha256:6d3f9c36…  (v5.83.0)
noetl-worker-system-pool          same
noetl-worker-system-pool-shard1   same
noetl-cmdbus-writer-0 / -1        same
scaledobject/noetl-worker-rust    ACTIVE, unpaused, 1 trigger (EHDB per-subject lag)
```

## The autoscaler is live — and the per-pool split earned its keep immediately

The user pool had **no autoscaling of any kind since 2026-07-26** (KEDA 2.15
deletes the HPA while `paused` is set). It now scales on
`ehdb_feed_subject_lag{subject="commands.shared.shard.0"}`.

The first scrape after deploy showed exactly why whole-shard lag was the wrong
trigger — the shard's entire backlog belonged to the *other* pool:

```
ehdb_feed_shard_lag{shard="0"} 4
ehdb_feed_subject_lag{subject="commands.shared.shard.0"} 0
ehdb_feed_subject_lag{subject="commands.system.shard.0"} 2
```

### Proof: 200 executions, min → max → min, every rescale attributed by name

```
SuccessfulRescale  New size: 2   … s0-metric-api-ehdb_feed_subject_lag{…} below target
SuccessfulRescale  New size: 4   … s0-metric-api-ehdb_feed_subject_lag{…} above target
SuccessfulRescale  New size: 8   … s0-metric-api-ehdb_feed_subject_lag{…} above target
SuccessfulRescale  New size: 16  … s0-metric-api-ehdb_feed_subject_lag{…} above target
SuccessfulRescale  New size: 20  … s0-metric-api-ehdb_feed_subject_lag{…} above target
```

200/200 COMPLETED, 0 duplicate ids, 0 publish errors.

## ⚠ The NATS trigger was not a no-op — it mis-scaled prod

ops#242 and [#210](https://github.com/noetl/ai-meta/issues/210) both stated the
second `nats-jetstream` trigger was harmless until the T5 teardown, because "this
consumer's backlog is permanently 0 now that the bus is EHDB."

Wrong. `noetl_worker_rust_shared` still holds the **149 messages undelivered when
the T4 cutover happened** (last delivery 2026-07-28). Nothing subscribes to it, so
that backlog is frozen, not draining. KEDA takes MAX across triggers:

```
TARGETS  0/2 (avg), 74500m/10 (avg)   REPLICAS  2   <- 21s after unpause
TARGETS  0/2 (avg), 37250m/10 (avg)   REPLICAS  4   <- 37s
                                      REPLICAS 15   <- 60s
```

The EHDB trigger read `0/2` correctly the whole time. Removed in ops#244 (applied
live first, the pool was actively mis-scaling). Evidence in
`hpa-natstrigger-misscale-evidence.txt`.

Generalisable: **at the scaler interface a stale queue is indistinguishable from a
busy one.** A trigger pointed at a transport that no longer carries work is not a
no-op; it is a stuck signal — the same failure the per-subject split exists to
prevent.

## #208 re-verified live, under load

Writer restarted **mid-burst** (60 executions in flight), workers untouched:

- **60/60 COMPLETED**, 0 publish errors — the #291 10 s retry window covered the
  ~2.7 s pod swap. Pre-fix this dropped one command per restart with an HTTP 500.
- Claimers redialed on their own; no worker restart needed.
- Resume was legible from one scrape, which is the whole point of #304:

```
ehdb_feed_shard_resume_from{shard="0",origin="persisted"} 9658
ehdb_feed_shard_resume_tip{shard="0"} 9725
ehdb_feed_shard_resume_stored{shard="0",clamped="false"} 9658
ehdb_feed_shard_resume_replay_records{shard="0"} 67
```

67 replayed records is the **unacked tail** being re-served — at-least-once
working as designed — not the from-zero whole-log replay that was #208's defect.
Before #304 those two cases produced indistinguishable log lines.

## Files here

| File | What |
|---|---|
| `ROLLBACK.md` | Rollback recipe, with the pre-change digests |
| `pre-t5-checklist.md` | **What still references NATS** — read this before T5 |
| `drive-load.sh` | Fire N synthetic executions at prod |
| `watch-scale.sh` | Per-tick lag / HPA / replica sampler |
| `soak.sh` | Repeated bursts asserting no loss / no dup / `out_of_order_appends == 0` |
| `rollback/` | Pre-change ScaledObject + Deployment YAML |
| `hpa-natstrigger-misscale-evidence.txt` | `describe hpa` capturing the mis-scale |

## Two measurement traps hit while doing this

Recorded because both produce *false failures*, which is worse than no data:

1. **Two soak instances against one cluster interleave.** One instance's drain
   check passes while the other's commands are still in flight, and it reads them
   as `NOT-COMPLETED` — indistinguishable from delivery loss. `soak.sh` now takes a
   lock.
2. **Lag hitting 0 means the bus drained, not that playbooks finished.** Sampling
   status once at that moment reports spurious misses; `soak.sh` now polls to a
   terminal state before declaring one.
