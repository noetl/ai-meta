# Handed object-store chooser GKE rollout to Codex (closes MinIO-elimination AMBER)

- date: 2026-05-11T18:00:00Z
- tags: gke, object-store, seaweedfs, rustfs, durability-test, post-noetl-430, codex-handoff

## Round goal

Close the AMBER from round 20260511-150000 (MinIO elimination). noetl#430
merged today, which unblocks:

1. ai-meta gitlink bump for repos/noetl
2. GKE rollout of the object-store chooser
3. Worker-restart durability proof on GKE
4. Travel agent activities smoke on GKE
5. Sync issue + validation log close-out

## State just changed

- noetl#430 merged: https://github.com/noetl/noetl/pull/430
- Engine-side comment/docstring MinIO sweep now on noetl main.
- ai-meta still points repos/noetl at pre-#430 main — phase 1 fixes that.
- GKE is on the previous noetl version (v2.37.8 from item #11), and the
  current GKE S3 endpoint isn't documented yet — phase 2 identifies it.

## Three possible GKE cases (phase 2 surfaces one)

**(a) In-cluster MinIO on GKE.** The session removed MinIO from kind but
not GKE in the prior round. If MinIO is still running on GKE, phase 3
deploys SeaweedFS via the helm chooser and removes the old MinIO.

**(b) Remote AWS S3 from GKE.** A different deployment model — the
chooser is for in-cluster backends, not cloud-routed storage. If this
is what GKE uses, no deploy change. The cloud-tier router decision
(GCS vs remote S3 vs in-cluster) is still a separate deferred item.

**(c) Already on the chooser.** Unlikely but possible. Confirm + skip.

## Phases (6)

1. Bump noetl gitlink (post-#430).
2. Inspect GKE S3 endpoint (case a/b/c).
3. Deploy chooser if case a; skip if case b; confirm if case c.
4. Worker-restart durability test (mandatory for case a/c; trivial for case b).
5. Travel agent activities smoke on GKE.
6. Close out — sync issue, validation log, memory entry.

## Cap

0 PRs expected. Pointer bump + deploy + smoke only. If GKE inspection
surfaces an unexpected fix, 1 small ops PR is permissible.

## Bridge artefacts

- `bridge/inbox/delegated/20260511-180000-object-store-chooser-gke-rollout.task.json`
- `scripts/object_store_chooser_gke_rollout_msg.txt`

## What success looks like

The sync issue's MinIO + Path B sections close cleanly. Cloud-tier
router decision remains the only open Path-B-adjacent item. The
durability test on GKE matches the kind result — worker-local-disk-only
is no longer the spillover failure mode on either cluster.

## Trigger prompt for Codex (paste this in after pushing)

```
noetl#430 merged. Close the AMBER from the MinIO elimination round.

Bridge task: bridge/inbox/delegated/20260511-180000-object-store-chooser-gke-rollout.task.json
Prompt details: scripts/object_store_chooser_gke_rollout_msg.txt
Result file: bridge/outbox/20260511-180000-object-store-chooser-gke-rollout.result.json
Sync issue to update: sync/issues/2026-05-11-gke-deployment-drift-and-storage-tier-audit.md

Run all 6 phases per the bridge task:
  1. Bump repos/noetl gitlink to post-#430 main.
  2. Inspect GKE S3 endpoint — case (a) in-cluster MinIO, (b) remote AWS,
     or (c) already on chooser.
  3. Deploy SeaweedFS via the helm chooser if case (a). Document + skip
     for case (b). Confirm + continue for case (c).
  4. Worker-restart durability test on GKE (rollout restart, etag match).
  5. Travel agent activities smoke on GKE.
  6. Close out — sync issue, validation log, memory entry.

Architectural rules:
  - Pointer bump + deploy + smoke only. No code changes.
  - If case (b) on remote AWS S3, do NOT migrate — that's a separate
    cloud-tier router decision still deferred.
  - Don't provision new GCP buckets.
  - Don't rotate credentials.
  - Don't cut a release.
  - No git push from ai-meta.

Pre-handoff: noetl#430 merged. ai-meta artefacts pushed.

If blocked: AMBER + STOP + document what's missing. Common blockers —
kubectl GKE access unavailable, helm conflicts, unexpected env vars.
```

## What's left after this lands

If GREEN: only deferred follow-ups remain — all explicitly tracked, none
blocking:

- Cloud-tier router decision (separate from in-cluster object store)
- Travel runtime workaround cleanup once v2.37.8 stable a few more days
- Ollama bridge deployment on GKE if real Ollama wanted
- Amadeus production API switch
- 14th authoring-guide rule pinning the kind→GKE parity process lesson

The session reaches its true completion point with this round. The
travel agent + platform + storage backend are all on the chooser
across both clusters.
