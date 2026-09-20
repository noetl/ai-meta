# ⚠⚠ ACTIVE PROD INCIDENT — cmdbus-writer OOM crash loop, dispatch down

**Found 2026-09-20 ~05:00 UTC while verifying prod was untouched. NOT caused by
this session** — prod access here has been read-only throughout, and the writer
had already been backing off for ~3h50m when it was found.

**Nothing was changed. This is a diagnosis, not a remediation.**

## What is happening

`noetl-cmdbus-writer-0`: **`CrashLoopBackOff`, 44 restarts, `exitCode 137 =
OOMKilled`**. It comes up, runs ~98 seconds, and is killed. Repeatedly.

That pod hosts **both buses** (cmdbus 9100-02, event bus 9103-08, tier service
9110), so the blast radius is dispatch:

```
noetl-worker-system-pool          0/1  CrashLoopBackOff
noetl-worker-system-pool-shard1   1/1  Running, 50 restarts
noetl-worker-rust                 2/2
```

with the workers reporting:

```
WARN noetl_worker::command_bus: EHDB claim connect failed; retrying
     claim_addr=noetl-cmdbus-writer-0...:9101 error=Connection refused (os error 111)
WARN noetl_worker::metrics_server: server-authored tier append did not land in full
     source="service" appended=0 requested=1 serve_state="not_primary" failures=1
```

## Root cause — measured, not inferred

```
/data/eventbus/ehdb-tier   3.9 G      <-- the tier store
/data/eventbus             346.3 M
/data/cmdbus               266.1 M
df /data/eventbus          4.3G used / 15.2G free  (22%)

container memory limit     4 Gi
```

**The tier store is 3.9 GB against a 4 GiB memory limit.** The startup timeline
matches exactly:

```
04:58:06  command-bus engine opened
04:58:26  events-feed engine opened
04:59:30  EHDB tier service listener up  store=/data/eventbus/ehdb-tier
04:59:44  OOMKilled                      <-- 14 seconds later
```

It dies immediately after opening the tier store.

⚠ **This is not a disk cliff** — 15.2 GB free. It is purely memory-at-open, and
it will recur at *any* fixed limit, because **the tier has no seal** (recorded
previously: the bus engines seal on `seal_max_age_ms=5000`, visible in this
pod's own startup log for `command-bus` and `events-feed`; the TIER has no
equivalent). An unsealed store grows without bound, and the memory needed to
open it grows with it.

## Recommended, for the owner — I did not do any of this

1. **Immediate:** raise the writer's memory limit above 4 Gi (8 Gi gives
   headroom against a 3.9 GB store) to break the loop and restore dispatch.
   ⚠ Per the standing note, roll it **surge-free** — `maxSurge` on a 1-replica
   pool means a second 3-4 Gi pod, and the writer mounts its PVCs **by name**.
2. **Then:** the real fix is bounding tier growth. A limit bump buys time
   proportional to how fast the tier grows; it does not stop this recurring.
3. Do **not** delete tier data to reclaim memory — it is the durable mirror of
   an append-only log.

## Why this is reported rather than fixed

Changing a prod resource limit is a prod change, and prod gates are the owner's.
It is also unrelated to the authorised work (the ehdb release and the
projector pathway), so it is not covered by that authorisation.

## Consequence for steps 4-6

The projector pathway is moot until this is resolved: step 4 would canary a
digest-fix server against a cluster whose writer is down, and step 5's shadow
soak would measure a system that is not dispatching. Coverage would read as
zero — and a soak that covers nothing reads as green falsely, which is the exact
failure the owner asked to avoid.

---

## Update 2026-09-20 ~23:45 — mitigation applied, and it is NOT sufficient

**Applied:** `limits.memory` 4Gi → **8Gi** on `noetl-cmdbus-writer` (surge-free
by construction: 1-replica StatefulSet, terminate-then-recreate,
`volumeClaimTemplates: []` so PVCs are mounted by name). Server-side dry-run
confirmed **only** that field changed. No tier data touched; both engines logged
`recovered_active_records=0`.

**Immediate result — dispatch restored:**

| | before | after |
| :-- | :-- | :-- |
| writer | OOMKilled ×13, dying every ~2h | Ready |
| `claim connect failed` per worker | 42 | **0** |
| events persisted | — | 231 in 5 min |

Positive control on the probe: the same grep read **42** over the window
spanning the outage and **0** after, so the zero is a reading rather than a
broken command.

**⚠ But it OOMed again at 8Gi**, at 23:04:56Z — nine seconds after the worker
roll began (23:04:47Z), having run 81 minutes.

**Corrected growth model.** An early two-point reading (2799 → 2977 Mi) looked
like linear growth and would have predicted exhaustion in ~14h; six samples then
showed a plateau at ~3.2 GiB, which looked safe. Both readings were too small a
window. From a known-fresh start the real shape is:

```
23:06:09   609Mi     <- boot
23:07:44  3138Mi     <- +95s, loading the 4.0 GB tier store
23:09:22  3030Mi
23:10:57  3030Mi     <- flat
23:12:33  3030Mi
```

So **~3 GiB is baseline** (proportional to the tier store on disk) and the run
to 8 GiB was **episodic**, triggered by a mass worker reconnect. KEDA scales the
user pool 1→20 routinely, so that trigger recurs on its own.

**Therefore: raising the limit does not fix this.** It raises the baseline
headroom against a spike whose size is not bounded, on top of a baseline that
grows with an **unsealed** tier store. Two things are needed and neither is a
resource edit:

1. Bound the writer's memory during a reconnect/claim burst.
2. Bound tier growth — the two bus engines log `seal_max_age_ms=5000`; the tier
   has no equivalent, so its store grows without limit and takes the baseline
   with it.

A further bump to 12Gi is available (Autopilot allows up to 6.5 GiB per vCPU;
at `cpu: 2` the ceiling is 13 GiB) and would buy more headroom, but it is a
delay, not a fix, and each patch costs a restart and its in-flight window.
