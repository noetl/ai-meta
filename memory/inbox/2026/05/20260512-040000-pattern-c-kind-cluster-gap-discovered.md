# Pattern C precondition state: GKE wired correctly; kind worker pod has separate ADC blocker
- Timestamp: 2026-05-12T04:00:00Z
- Author: Kadyapam
- Tags: travel-agent, google-places, pattern-c, workload-identity, kind, gke, gcs-credentials, deployment-blocker, playbook-update, precondition-check

## Summary

Pre-flight check of the Pattern C setup playbook before firing the
`20260512-030000-google-places-enrichment-mcp` bridge round. Result: **GKE is
ready, kind has a separate (unrelated) blocker.** The Pattern C round can fire
on GKE as soon as the widget API key (Steps 4-5) is created.

## GKE state — Pattern C target cluster (`noetl-cluster`, us-central1)

Worker pod (`noetl-worker-*`) in `noetl` namespace:

- ✅ No `GOOGLE_APPLICATION_CREDENTIALS` env var set anywhere (deployment env,
  envFrom configMap `noetl-worker-config`).
- ✅ No `/etc/gcs` volume mount. The Helm-rendered GKE deployment does not
  include the placeholder mount that the in-repo `worker-deployment.yaml`
  carries.
- ✅ k8s SA `noetl-worker` has annotation
  `iam.gke.io/gcp-service-account: noetl-worker-mcp@noetl-demo-19700101.iam.gserviceaccount.com`.
- ✅ GKE cluster has Workload Identity enabled
  (`workloadPool = noetl-demo-19700101.svc.id.goog`).
- ✅ `noetl-worker-mcp@noetl-demo-19700101.iam.gserviceaccount.com` exists, not disabled.
- ✅ GCP SA has `roles/iam.workloadIdentityUser` granted to k8s member
  `serviceAccount:noetl-demo-19700101.svc.id.goog[noetl/noetl-worker]`.

Project-level GCP setup:

- ✅ Maps Platform APIs enabled: `places.googleapis.com`, `places-backend.googleapis.com`,
  `routes.googleapis.com`, `static-maps-backend.googleapis.com`,
  `maps-backend.googleapis.com`, plus Android/iOS/Embed variants.
- ✅ `noetl-worker-mcp` has on the project:
  `roles/aiplatform.user`, `roles/container.viewer`, `roles/mcp.toolUser`,
  `roles/serviceusage.serviceUsageConsumer`.
- ❌ Secret `google-maps-widget-key` does NOT exist in Secret Manager.
- ✅ **Backend SA OAuth probe (playbook Step 3) executed and GREEN** from
  worker pod `noetl-worker-77bf5b5897-f2dtx` on 2026-05-12. `places:searchText`
  for "restaurants in Paris" returned `STATUS: 200`, `CRED_TYPE: Credentials`,
  `SA_EMAIL: noetl-worker-mcp@noetl-demo-19700101.iam.gserviceaccount.com`.
  Real Paris restaurants in body (Pink Mamma, Le Ju', etc.). End-to-end
  metadata-server → WI → noetl-worker-mcp → Places API path verified.

Playbook Steps 1, 2, 3 plus all pod-level WI wiring are complete on GKE.
Remaining: Steps 4 (widget key in Cloud Console) and 5 (push key to Secret
Manager).

## kind state — separate, unrelated blocker (`kind-noetl`, local)

Pre-flight surfaced an unrelated deployment bug while probing on kind:

- `noetl-worker` pod has `GOOGLE_APPLICATION_CREDENTIALS=/etc/gcs/gcs-key.json`
  hardcoded via `repos/ops/ci/manifests/noetl/worker-deployment.yaml` and the
  noetl-submodule mirror.
- The mount comes from secret `gcs-credentials` containing `gcs-key.json: '{}'`
  — a 2-byte placeholder created by `repos/ops/automation/development/noetl.yaml`
  (line 229) when no real key is present. The GKE doc
  (`repos/docs/docs/operations/mcp/end-to-end-gke.md`, line 115) flags this as
  "only good enough for non-GCS-backed playbooks."
- `google.auth.default()` reads that env-pointed file before any fallback, so
  the placeholder fails the worker with `Type is None` and blocks every other
  auth path — including all GCS-backed code, not just Pattern C.

This is a kind-side deployment-hygiene bug. Pattern C is GKE-only, so this
blocker does not gate the round; it gates kind-local GCP smoke tests.

## Cluster delta — `noetl-worker-mcp` is the GCP SA name on GKE only

Prior memory entries (`20260512-000000-cloud-tier-gcs-implementation-gke-green.md`,
`20260511-230000-amadeus-production-api-switch-code-only-green.md`) reference
`noetl-worker-mcp` as the worker SA. That is the **GCP** service account email.
The **k8s** ServiceAccount in both clusters is `noetl-worker`; on GKE it is
WI-annotated to impersonate `noetl-worker-mcp`, on kind it is plain (no WI
possible). Future memory should say "k8s SA `noetl-worker` impersonating GCP
SA `noetl-worker-mcp`" when precision matters.

## Actions

- Patched `playbooks/google-maps-platform-setup-pattern-c.md`:
  - Added "Cluster context — GKE only" preamble documenting the kind/GKE delta
    and warning that Pattern C is GKE-only.
  - Added troubleshooting entry for the kind `Type is None` failure with
    diagnose commands and per-cluster fix paths.
- Verified GKE Pattern C preconditions (gcloud + kubectl, read-only).
- Ran Step 3 SA OAuth probe inside `noetl-worker-77bf5b5897-f2dtx` (user
  authorized): GREEN, `STATUS: 200` from `places:searchText`.
- Did NOT mint the widget API key (Steps 4-5) — Step 4 is a Cloud Console UI
  action; Step 5's `gcloud secrets create` should be run by the user so the
  key value never enters this transcript (per playbook safety note).
- Did NOT touch the kind-side deployment manifest. That fix lives in noetl /
  ops submodules and is a separate bridge round if/when kind-side GCP smoke
  testing becomes needed.

## Remaining for the Pattern C round to fire

1. Run Step 4 (Cloud Console UI) to mint `travel-agent-widget-key` with
   referrer + API restrictions per the playbook.
2. Run Step 5 (`gcloud secrets create google-maps-widget-key ...`) and grant
   `roles/secretmanager.secretAccessor` to `noetl-worker-mcp`.
3. Commit the bridge artefacts and paste the Step 8 trigger prompt into Codex.

## Repos
- ai-meta (this entry, playbook patch)

## Related
- playbooks/google-maps-platform-setup-pattern-c.md
- bridge/inbox/delegated/20260512-030000-google-places-enrichment-mcp.task.json
- memory/inbox/2026/05/20260512-030000-handed-google-places-enrichment-to-codex.md
- repos/ops/ci/manifests/noetl/worker-deployment.yaml (kind-side env/mount source)
- repos/ops/automation/development/noetl.yaml (line 229, placeholder secret creation)
- repos/docs/docs/operations/mcp/end-to-end-gke.md (line 115, "only good enough for non-GCS-backed playbooks")
