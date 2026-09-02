# ehdb#332 — give the EHDB tier its own failure domain (staged, owner-run)

**Nothing in this runbook has been executed.** The inert half is
noetl/ops#295 (declared, *not applied*). Everything below is a prod infra +
data-movement operation.

## Why

```
NOETL_EHDB_TIER_SERVICE_DIR = /data/eventbus/ehdb-tier   <- inside
NOETL_EVENT_BUS_WRITER_DIR  = /data/eventbus             <- this
```

One PVC holds both. That is cutover blocker **C7**: serving reads from a tier
that shares a volume with the log it is meant to be independent of converts a
one-disk *durability* problem into a one-disk *availability* problem.

## What is already inert-merged vs. what needs an owner-run deploy

| piece | state |
| :-- | :-- |
| `noetl-ehdb-tier-0-data` PVC declared (30Gi, premium-rwo) | ops#295 — **merged, not applied** |
| `/data/ehdb-tier` mount on the writer | ops#295 — **merged, not applied** |
| `NOETL_EHDB_TIER_SERVICE_DIR` repointed | **not done** — step 3 below |
| existing tier data relocated | **not done** — step 2 below |

## Blast radius

The writer is a **single pod** and hosts **both** L0 engines (cmdbus on
:9100-9102, eventbus on :9103-9108) plus the tier service on :9110. Any restart
is a **~90 s platform-wide dispatch interruption** — the server redials, and
`POST /api/execute` fails for that window. There are two restarts below
(attach, then repoint), so budget two windows or combine steps 1 and 3.

The tier is currently `shadow` for projection and not serving reads, so **losing
tier data would not break serving** — but it would reset the equivalence
baseline, which is the thing gating the cutover. Copy, verify, then delete.

## Steps

### 1 — attach the new volume (no data moves)

```bash
CTX=gke_shastaratech-noetl-prod_us-central1_noetl-prod-autopilot
kubectl --context $CTX apply -f ci/manifests/noetl/pvc-ehdb-storage-prod.yaml
kubectl --context $CTX apply -f ci/manifests/noetl/cmdbus-writer-statefulset-prod.yaml
kubectl --context $CTX -n noetl rollout status statefulset/noetl-cmdbus-writer --timeout=420s
kubectl --context $CTX -n noetl exec noetl-cmdbus-writer-0 -- df -h /data/ehdb-tier
```
⚠ Applying the **whole** StatefulSet manifest re-asserts every field in it. Per
ai-meta#267 the prod manifests have drifted from live in the past — diff before
applying:
```bash
kubectl --context $CTX -n noetl diff -f ci/manifests/noetl/cmdbus-writer-statefulset-prod.yaml
```
**Read that diff.** If it shows anything beyond the new volume/mount, stop.

### 2 — copy the tier data (writer still serving from the old path)

```bash
kubectl --context $CTX -n noetl exec noetl-cmdbus-writer-0 -- sh -c '
  cp -a /data/eventbus/ehdb-tier/. /data/ehdb-tier/ &&
  echo "src: $(du -sh /data/eventbus/ehdb-tier | cut -f1)  dst: $(du -sh /data/ehdb-tier | cut -f1)" &&
  echo "src files: $(find /data/eventbus/ehdb-tier -type f | wc -l)  dst files: $(find /data/ehdb-tier -type f | wc -l)"'
```
**Gate: sizes and file counts must match before step 3.** The tier is actively
written while this runs, so expect the destination to be a few records behind;
re-run the copy immediately before step 3 to close the gap.

### 3 — repoint and restart

```bash
kubectl --context $CTX -n noetl set env statefulset/noetl-cmdbus-writer \
  NOETL_EHDB_TIER_SERVICE_DIR=/data/ehdb-tier
kubectl --context $CTX -n noetl rollout status statefulset/noetl-cmdbus-writer --timeout=420s
```

### 4 — verify

```bash
kubectl --context $CTX -n noetl logs noetl-cmdbus-writer-0 | grep "tier service listener up"
# expect: store=/data/ehdb-tier
kubectl --context $CTX -n noetl exec noetl-cmdbus-writer-0 -- df -h /data/ehdb-tier /data/eventbus
```
Then re-run the equivalence sweep and expect the **29/29 baseline** to hold. A
drop means the copy lost something — roll back rather than investigate live.

## Rollback — one command, no data loss

The old directory is left in place untouched by steps 1–3:

```bash
kubectl --context $CTX -n noetl set env statefulset/noetl-cmdbus-writer \
  NOETL_EHDB_TIER_SERVICE_DIR=/data/eventbus/ehdb-tier
kubectl --context $CTX -n noetl rollout status statefulset/noetl-cmdbus-writer --timeout=420s
```

### 5 — reclaim (only after a soak, and only once)

Delete `/data/eventbus/ehdb-tier` **only** after the new path has served
correctly for at least a full sweep cycle. Until then it is the rollback target.
This step is deliberately not scripted here.

## Note on what this does and does not buy

Separating the volumes gives the tier an independent *disk*. It does **not** by
itself give an independent *node* — both PVCs attach to the same single writer
pod. That is sufficient to unblock C7's "shared volume" objection and is a
prerequisite for ehdb#322's quorum-ack, but a node loss still takes both until
there is more than one writer, which is blocker C5's territory.
