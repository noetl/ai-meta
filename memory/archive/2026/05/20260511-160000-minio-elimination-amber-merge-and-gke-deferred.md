# MinIO elimination round closes AMBER — local GREEN, noetl PR blocked on review, GKE deferred

- date: 2026-05-11T16:00:00Z
- tags: infra, object-store, minio-removed, seaweedfs-default, rustfs-opt-in, amber, gke-deferred

## What landed

- Ops PR merged: noetl/ops#70 — manifests, helm chart chooser, infrastructure
  playbook, bootstrap/destroy updates
- Docs PR merged: noetl/docs#60 — operations docs reflect the chooser
- noetl PR open: noetl/noetl#430 — CI passed, blocked on required review
  (process gate, not technical)
- Local kind: SeaweedFS as default, accessible at
  `object-store.object-store.svc:9000`
- RustFS opt-in path smoke-tested; fixed UID 10001 permissions in flight
- Worker restart durability check PASSED — object written pre-rollout was
  readable post-rollout. This is the proof that worker-local-disk-only is
  no longer the spillover failure mode.

## Validation

- Helm lint clean
- Helm render + kubectl client dry-run clean for both backends
- Raw manifests dry-run clean for both backends
- Docs `npm run build` clean
- NoETL targeted storage tests: 19 passed
- Product-source grep across merged ops/docs plus the noetl#430 branch:
  no remaining MinIO identifiers. Current ai-meta still points `repos/noetl`
  at main while #430 is review-blocked, so noetl main still contains the
  old wording until that PR merges.

## Why AMBER (not GREEN)

Two gates:

1. **noetl#430 blocked on required review.** Engine-side comment/docstring
   sweep landed but can't merge without a reviewer touching it. The
   functionality is unchanged so review should be quick — but until
   merged, the gitlink can't be bumped.

2. **GKE deployment deferred** until noetl#430 merges + gitlinks align.
   Bumping GKE before the engine code is stable would be premature; the
   correct ordering is engine PR → gitlink → GKE rollout.

Once the noetl review lands, the GKE deploy is straightforward — the
helm chart already has the chooser, the manifests already exist for both
backends, and the noetl-server/worker env is already endpoint-agnostic.

## Completeness verification

Verified after the ops/docs merges:

```bash
cd repos/ops
git log --oneline --diff-filter=D -- automation/infrastructure/minio.yaml | head -5
# 8ed7e24 feat(storage): replace MinIO with object-store chooser

ls automation/infrastructure/ | grep -i minio    # returned nothing
ls ci/manifests/ | grep -i minio                 # returned nothing

cd ../docs
git log --oneline --diff-filter=D -- docs/development/minio.md | head -5
# 8c712c2 docs(storage): document SeaweedFS/RustFS object store
ls docs/development/ | grep -i minio             # returned nothing
```

No deprecation stubs survived in the merged ops/docs repos. The remaining
MinIO references are in `repos/noetl` main only because noetl#430 is open
and review-blocked.

## What's actually deferred from this round

- **noetl#430 review + merge.** Process gate.
- **GKE deploy of the chooser.** Gated on the above.
- **GKE smoke (durability + chooser swap).** Gated on the deploy.
- **NoETL cleanup pointer** after noetl#430 merges.

## Bridge artefacts staged

- Bridge task + result file in ai-meta
- Memory entries (handoff + this close-out + Codex's
  `20260511-122310-minio-eliminated-object-store-chooser-amber.md`)
- Sync issue update
- ops/docs submodule pointer bumps

Not pushed.

## Trigger for the next round (after noetl#430 merges)

```
noetl#430 (MinIO comment/docstring sweep) is merged. Bump the repos/noetl
gitlink in ai-meta to the merge SHA, then deploy the object-store chooser
to GKE.

Phases:
  1. Pull merged noetl, bump ai-meta repos/noetl pointer.
  2. Inspect current GKE S3 endpoint — was it in-cluster MinIO or remote
     AWS S3? Document the distinction.
  3. If in-cluster: deploy SeaweedFS via the chooser. Confirm
     object-store Service is reachable from noetl-server/worker pods.
  4. Worker-restart durability test on GKE: same proof as kind.
  5. Smoke the travel agent activities path on GKE — confirm storage tier
     behavior matches kind.
  6. Update sync issue, validation log, memory entry.
```

Codex can pick this up via a small smoke-only bridge round when the
review lands.

## Connects back to earlier session findings

- **Path B from round 20260511-110000**: the in-cluster S3 backend
  replacement is what this round delivers. Cloud-tier router decision
  (GCS vs in-cluster S3 vs remote AWS S3 for durable storage) is still
  separate and stays deferred.

- **Process rule reinforced**: "kind deploys need a chained GKE-parity
  round." This round documents it explicitly via the AMBER — local GREEN
  doesn't mean GKE GREEN. The 14th authoring-guide rule discussion in
  earlier notes should formalize this.

- The session has now demonstrated this drift in TWO consecutive rounds
  (GKE parity sync + MinIO elimination). Worth pinning as a rule before
  the next big infra round.
