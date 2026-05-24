---
thread: 2026-05-23-gke-provision-validation
round: 1
from: claude
to: codex
created: 2026-05-23T22:00:00Z
status: open
expects_result_at: round-01-result.md
---

# Provision NoETL on GKE + run regression tests

You are operating in `/Volumes/X10/projects/noetl/ai-meta`. Read
`handoffs/README.md` and `agents/rules/handoffs.md` first. The
predecessor context for this round is the v2-spec close-out
documented at
`repos/docs/docs/features/noetl_distributed_runtime_spec.md` §0
("Status — all seven phases done"). Read at least §0 + §0.1 +
§0.2 + §0.3 of that doc before starting — it tells you what
landed, where things live, and what was already validated in
local kind.

## Target cluster

GKE Autopilot cluster already exists:

- **Project:** `noetl-demo-19700101`
- **Region:** `us-central1`
- **Cluster name:** `noetl-cluster`
- **Console:** <https://console.cloud.google.com/kubernetes/clusters/details/us-central1/noetl-cluster/overview?project=noetl-demo-19700101>

Get credentials via:

```bash
gcloud container clusters get-credentials noetl-cluster \
  --region us-central1 --project noetl-demo-19700101
```

Confirm context with `kubectl config current-context` —
should resolve to something like
`gke_noetl-demo-19700101_us-central1_noetl-cluster`.

## What this round delivers

A working NoETL stack on GKE:

1. **Postgres + NATS + paginated test-server + NoETL
   (server/projector/outbox-publisher/worker)** deployed via
   the ops playbook.
2. **KEDA scaler** installed and the worker-pool ScaledObject
   applied; HPA created and reading lag from NATS.
3. **NATS supercluster** topology applied (cluster `a` +
   cluster `b`) with bidirectional gateway connectivity.
4. **Regression tests run** against the deployed stack with
   metrics captured.
5. A **comparison report** vs. the 2026-05-23 local-kind
   validation evidence (see v2-spec doc §0.3) so any
   GKE-specific divergence is visible.

## Phases

### Phase A — environment + auth (no remote writes outside GKE)

1. Confirm `gcloud auth application-default login` is current
   and `gcloud container clusters get-credentials ...` works.
2. Confirm `kubectl config current-context` resolves to the
   target cluster. **If it points anywhere else (e.g.
   `kind-noetl`), stop and confirm with the human before
   proceeding** — the rest of this prompt assumes you're
   pointed at the GKE cluster.
3. Read the existing GKE docs for context:
   - `repos/docs/docs/features/gke_autopilot_full_provisioning.md`
   - `repos/docs/docs/features/gke_autopilot_service_protection.md`
   - `repos/docs/docs/features/iap_gcp_autopilot_deploy.md`
   They predate the Scope A/B consolidation; treat them as
   reference for the GKE-specific surface (Artifact Registry,
   Workload Identity, ingress, etc.) but use the
   post-Scope-B `noetl/ops/automation/development/noetl.yaml`
   path for the actual deploy.
4. Sync submodules to current main:
   ```
   git -C repos/ops fetch origin && git -C repos/ops checkout main && git -C repos/ops pull origin main
   git -C repos/noetl fetch origin && git -C repos/noetl checkout main && git -C repos/noetl pull origin main
   ```
   Expected tips (or newer):
   - `repos/ops`: includes `noetl/ops#114` (operator
     friendliness fixes). If not yet merged, also check
     `kadyapam/deploy-playbook-operator-fixes` branch — those
     fixes are required for the reset/redeploy flow to work
     cleanly.
   - `repos/noetl`: includes `noetl/noetl#599` (Scope B
     deletion of `ci/manifests/`).

### Phase B — image strategy

The local-kind playbook builds images locally and loads them
into the kind cluster. GKE Autopilot can't pull `localhost/...`
images — they need to come from a registry. Two paths; pick
based on what's available:

5. **Preferred: use a published image tag from Artifact
   Registry.** If `us-central1-docker.pkg.dev/noetl-demo-19700101/noetl/noetl:<tag>`
   exists, use it directly:
   ```
   cd repos/ops
   noetl run automation/development/noetl.yaml --runtime local \
     --set action=deploy \
     --set registry=us-central1-docker.pkg.dev/noetl-demo-19700101/noetl \
     --set image_name=noetl \
     --set image_tag=<tag> \
     --set image_pull_policy=IfNotPresent \
     --set verify_test_server_contract=false \
     --set podman_machine=
   ```
6. **Fallback: build + push then deploy.** If no usable tag
   exists, build a fresh image and push to Artifact Registry
   first:
   ```
   gcloud auth configure-docker us-central1-docker.pkg.dev
   cd repos/noetl && docker build -f docker/noetl/dev/Dockerfile -t us-central1-docker.pkg.dev/noetl-demo-19700101/noetl/noetl:$(date +%Y-%m-%d) .
   docker push us-central1-docker.pkg.dev/noetl-demo-19700101/noetl/noetl:$(date +%Y-%m-%d)
   ```
   Then run the deploy with `image_tag` set to the same tag.
7. **Note on `paginated-api`:** the test-server image is also
   local-only by default. Pass
   `--set verify_test_server_contract=false` to skip the
   contract check; the test playbooks don't need
   paginated-api for the regression scope below.

### Phase C — storage on GKE

Local-kind uses hostPath / standard storage class. GKE Autopilot
expects PVCs to bind via dynamic provisioning (default
`standard-rwo` storage class for RWO, `standard-rwx` or
`premium-rwx` for RWX). The manifests in
`repos/ops/ci/manifests/postgres/` and
`repos/ops/ci/manifests/noetl/` use **static `PersistentVolume`s
with `hostPath`** — those won't bind on GKE.

8. **Audit which PVCs need GKE-specific storage classes.**
   Look at:
   - `repos/ops/ci/manifests/postgres/persistent-volume.yaml`
   - `repos/ops/ci/manifests/noetl/pvc-noetl-data.yaml`
   - `repos/ops/ci/manifests/nats/nats.yaml` (StatefulSet
     volumeClaimTemplates)
9. **Decide the per-PVC fix.** Two options per PVC:
   - **Patch in-place:** create a sibling
     `<manifest>-gke.yaml` overlay that swaps `hostPath` PVs
     for PVC-only definitions using a real GKE storage class.
     Keep the kind manifests as-is.
   - **Drop the static PV reference:** modify the existing PVC
     to `storageClassName: standard-rwo` (or
     `premium-rwx`/`filestore-csi`/etc. for shared) and remove
     the static PV.
   Recommend option 1 (overlay) — keeps kind flow intact.
10. Apply the overlays from
    `ci/manifests/<dir>/*-gke.yaml` after the playbook's main
    manifests, OR add a `gke=true` flag to the playbook that
    swaps the order. Pick the simplest path that lets you
    proceed; the playbook polish lands separately.

### Phase D — install KEDA on GKE

11. Install KEDA via Helm into the cluster:
    ```
    helm repo add kedacore https://kedacore.github.io/charts || true
    helm repo update kedacore
    helm install keda kedacore/keda --namespace keda --create-namespace --version 2.15.0
    kubectl rollout status deployment/keda-operator -n keda --timeout=120s
    ```
12. Apply the worker-pool ScaledObject:
    ```
    kubectl apply -f repos/ops/ci/manifests/keda/scaledobject-worker-cpu-01.yaml
    ```
13. Confirm `kubectl get scaledobject,hpa -n noetl` shows the
    scaler `READY=True` and the HPA created.

### Phase E — install NATS supercluster on GKE

14. Apply the supercluster manifests:
    ```
    kubectl apply -f repos/ops/ci/manifests/nats-supercluster/namespace.yaml
    kubectl apply -f repos/ops/ci/manifests/nats-supercluster/cluster-a.yaml
    kubectl apply -f repos/ops/ci/manifests/nats-supercluster/cluster-b.yaml
    kubectl rollout status statefulset/nats-cluster-a -n nats-supercluster --timeout=300s
    kubectl rollout status statefulset/nats-cluster-b -n nats-supercluster --timeout=300s
    ```
15. **Watch for storage-class issues** — the supercluster
    StatefulSets also use `volumeClaimTemplates` which need a
    valid GKE storage class. If pods stay Pending on PVC
    binding, the templates need a `storageClassName` field
    set; document the fix and patch as a sibling
    `cluster-{a,b}-gke.yaml` overlay.
16. Verify the gateway mesh works on GKE:
    ```
    kubectl port-forward -n nats-supercluster nats-cluster-a-0 18222:8222 &
    sleep 4
    curl -s http://localhost:18222/gatewayz | jq '{outbound: .outbound_gateways | keys, inbound: .inbound_gateways | keys}'
    ```
    Expected: `outbound: ['b']`, `inbound: ['b']`. Bidirectional
    mesh confirmed.

### Phase F — regression tests + metrics

17. **NoETL API health:**
    `curl -s -o /dev/null -w "HTTP %{http_code} in %{time_total}s\n"`
    against the ingress / LB / port-forward whichever path you
    pick for external access. Capture latency.
18. **Catalog accessible:**
    `noetl --host <gke-endpoint> --port <port> list Playbook --json | jq '.entries | length'` —
    capture playbook count. (Cluster is fresh; expect 0
    unless previously seeded. If you need playbooks, register
    `test/simple_python` via `noetl catalog` first.)
19. **Test playbook execution (5 runs of `test/simple_python`):**
    ```
    for i in 1 2 3 4 5; do
      RESP=$(noetl --host <gke> --port <port> exec --json test/simple_python)
      EID=$(echo "$RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['execution_id'])")
      until noetl --host <gke> --port <port> status $EID --json | python3 -c "import sys,json; d=json.load(sys.stdin); sys.exit(0 if d.get('completed') else 1)"; do sleep 1; done
      DUR=$(noetl --host <gke> --port <port> status $EID --json | python3 -c "import sys,json; print(json.load(sys.stdin)['duration_seconds'])")
      echo "  run $i: ${DUR}s"
    done
    ```
    Capture all 5 durations.
20. **DB connection footprint:**
    ```
    kubectl exec -n postgres deploy/postgres -- psql -U noetl -d noetl \
      -c "SELECT client_addr, state, count(*) FROM pg_stat_activity
          WHERE datname='noetl' AND client_addr IS NOT NULL
          GROUP BY client_addr, state ORDER BY 3 DESC;"
    ```
    Map IPs to pods via `kubectl get pods -n noetl -o wide`.
21. **KEDA scale-up smoke:** if there's a `nats` CLI available
    (or run `kubectl run --rm nats-box --image=natsio/nats-box`),
    publish a 200-message burst to drive lag, watch
    `kubectl get hpa -n noetl -w` for the scale-up cycle. If
    KEDA + supercluster + GKE Autopilot interact differently
    than local kind (e.g. Autopilot may delay node provisioning
    for new worker pods), record the observed scaling timeline.
22. **Comparison vs. local-kind §0.3:** for each metric
    captured locally (DB conns, test playbook latency, KEDA
    scale-up timeline), write the GKE side-by-side. The local
    numbers:
    - DB idle conns: 15 (8 server + 5 projector + 2 outbox + 0
      workers)
    - test/simple_python: 1.20s cold → 0.66s warm steady
    - KEDA scale-up: 200 msg → 4 → 8 → 16 → 20 in ~35s,
      drain → 1 over HPA stabilization (~5 min)

### Phase G — write the result + open follow-up issues

23. Write the result file at the path declared in this prompt's
    frontmatter. Body sections — one H2 per Phase A–F, plus
    `## Issues observed` and `## Manual escalation needed`.
24. For each GKE-specific divergence (storage class overlays,
    image-tag handling, ingress, etc.) that's worth landing as
    a permanent improvement, **open a follow-up handoff** under
    `handoffs/active/<slug>/round-01-prompt.md` rather than
    blocking on it here. The goal of this round is "stack
    operational + regression evidence captured"; turning the
    GKE deploy into a first-class path is a separate effort.
25. If anything in Scope A/B's foundation is broken on GKE
    (e.g. the local-path-only assumption surfaces in more
    places than just storage classes), surface it explicitly
    so the consolidation can be hardened.

## Hard rules

- **Don't merge any PRs as part of this round.** Open them
  with a clear summary, then stop.
- **No force-push.**
- **No secrets in any file under ai-meta.** GCP
  service-account JSON, kubeconfigs, etc. stay out of the
  repo.
- **Don't blow away the kind cluster** — the local validation
  evidence is the comparison baseline. The GKE work runs in
  parallel.
- **If you find that the playbook reads from
  `$NOETL_REPO/ci/manifests/...` anywhere, that's a Scope B
  regression** — flag it. The post-Scope-B state has zero
  such references in `noetl/ops/automation/development/noetl.yaml`.
- **Respect `agents/rules/wiki-maintenance.md` Rule 0** — any
  GKE-specific wiki content lands in the `noetl/ops` wiki
  (https://github.com/noetl/ops/wiki), not the noetl-noetl
  wiki. The chronological doc in `noetl/docs` may also get
  an entry if a substantive architectural decision lands.

## What success looks like

- All NoETL pods Running on GKE.
- KEDA scaler `READY=True` against the worker pool.
- NATS supercluster bidirectional gateway mesh confirmed.
- 5 successful `test/simple_python` executions; warm-steady
  latency captured.
- DB connection footprint captured + within an order of
  magnitude of local-kind baseline.
- A round-01-result.md that any future agent (or human) can
  use to reproduce the GKE provisioning + regression run.

## What to defer

- Building a full HA NoETL on GKE (multi-zone supercluster,
  CloudSQL postgres, etc.) — this round is "reproduce local
  kind on GKE Autopilot end-to-end," not "production
  hardening."
- IAP / DNS / TLS publishing — out of scope. Use port-forward
  for any external testing.
- Workload Identity wiring for cloud storage — only matters if
  the test playbooks actually need it. Skip if not blocking.
- Updating the chronological PR log in
  `repos/docs/.../noetl_distributed_runtime_spec.md` with
  GKE-specific PRs. Section 0 already references this work
  forward; line-level entries can come later.

## FINAL REPORT

Body sections — one H2 per Phase A–G, plus `## Issues observed`
and `## Manual escalation needed`. Include:

- Final pod listing (`kubectl get pods -A` filtered to
  noetl + nats + postgres + nats-supercluster + keda).
- The five `test/simple_python` durations.
- DB connection breakdown (client_addr → pod → state →
  count).
- KEDA scale-up timeline if you drove the smoke burst.
- Side-by-side comparison vs. the local-kind §0.3 numbers.
- All open follow-up handoffs you created.
