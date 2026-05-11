# MinIO eliminated; SeaweedFS/RustFS chooser AMBER

Date: 2026-05-11

The MinIO elimination round is locally validated and partially merged.

Merged:

- `noetl/ops#70` — removed MinIO deployment/playbook/manifests and added `objectStore.kind: seaweedfs | rustfs`, defaulting to SeaweedFS. Both backends expose `object-store.object-store.svc:9000`.
- `noetl/docs#60` — replaced the MinIO development page with object-store docs and swept docs toward S3-compatible object-store terminology.

Open:

- `noetl/noetl#430` — code-path-neutral naming cleanup for comments/docstrings/schema/static manifests. CI passed (`forbid-client-term`), but the PR is review-blocked, so the ai-meta noetl pointer was not bumped.

Local kind proof:

- SeaweedFS rolled out in `object-store` namespace and passed S3 create/put/get through the canonical service.
- SeaweedFS object data survived object-store pod deletion/restart.
- RustFS initially crash-looped because the image runs as UID 10001 and could not write `/logs` or the hostPath-backed `/data`; fixed with `/logs` emptyDir plus a root initContainer that chowns/chmods `/data` and `/logs`.
- RustFS then rolled out and passed the same S3 create/put/get smoke through `object-store:9000`.
- The cluster was returned to the default SeaweedFS backend.
- NoETL server/worker configmaps were updated locally to `NOETL_S3_ENDPOINT=http://object-store.object-store.svc.cluster.local:9000`, bucket `noetl`, credentials `noetl-access/noetl-secret`, and `NOETL_STORAGE_CLOUD_TIER=s3`.
- A worker-pod boto3 put/get survived full worker-pod deletion/restart, proving the new object-store tier is not worker-local disk.

Validation:

- Helm lint passed.
- Helm render + kubectl client dry-run passed for both `objectStore.kind=seaweedfs` and `objectStore.kind=rustfs`.
- Raw manifest kubectl client dry-run passed for both backends.
- Docs `npm run build` passed.
- NoETL targeted storage tests passed: `19 passed`.
- Product-source grep found no remaining MinIO identifiers across ops/docs main and the noetl#430 cleanup branch. Current ai-meta still points `repos/noetl` at main because #430 is unmerged, so noetl main still has the old wording until review lands.

Round status is AMBER, not GREEN, because noetl#430 remains review-blocked and the GKE smart-adapt replacement phase was intentionally not run against unmerged/pointer-incomplete state.
