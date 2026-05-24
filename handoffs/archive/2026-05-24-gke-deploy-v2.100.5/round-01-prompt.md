---
thread: 2026-05-24-gke-deploy-v2.100.5
round: 1
from: claude
to: codex
created: 2026-05-24T01:30:00Z
status: open
expects_result_at: round-01-result.md
---

# Deploy noetl v2.100.5 to GKE + verify the three landed fixes

You are operating in `/Volumes/X10/projects/noetl/ai-meta`. Read
`handoffs/README.md` and `agents/rules/handoffs.md` first.

## Predecessor context

You already worked this cluster in the **2026-05-23 GKE provision
validation** round
(`handoffs/archive/2026-05-23-gke-provision-validation/round-01-result.md`)
and the **GKE worker consumer-missing diagnostic** round
(`handoffs/archive/2026-05-23-gke-worker-consumer-missing/round-01-result.md`).
You know the cluster: it's Helm-managed against
Cloud SQL + PgBouncer, NATS is Helm-deployed, the worker is on
the May-20 `e3db3624` image, and the durable consumer was missing
until you provisioned it manually.

Three fixes have since landed on `noetl/noetl main`:

- **PR #600** (v2.100.3) — `fix(worker): recover missing nats
  durable consumer`. Adds `_recover_fetch_subscription()` to
  `NATSCommandSubscriber`. The fetch loop now self-heals if the
  consumer drifts away at runtime (rate-limited 30s).
- **PR #601** (v2.100.4) — `fix(logging): redact userinfo from
  NATS / Postgres / HTTP URLs in logs`. Worker startup logs +
  `/tmp/worker_config.txt` no longer leak embedded
  `user:password@` credentials.
- **PR #602** (v2.100.5) — `fix(catalog): distinguish empty vs
  missing terminal scopes; skip None entries`. Semantic fix to
  `CatalogService._extract_agent_metadata`.

All three are in the **same image** at tag `v2.100.5` once built.

## Target

GKE Autopilot cluster `noetl-cluster` in `us-central1`, project
`noetl-demo-19700101`. The image needs to land at
`us-central1-docker.pkg.dev/noetl-demo-19700101/noetl/noetl:v2.100.5`
and the Helm release `noetl` (namespace `noetl`) needs to roll
the new image in.

## What this round delivers

1. Image built at `v2.100.5` and pushed to Artifact Registry.
2. Helm release upgraded to use the new tag.
3. NoETL pods rolled with zero workload disruption (rolling
   update; `noetl-server` strategy is `RollingUpdate` by default).
4. Verification evidence captured for each of the three fixes:
   - **#600**: delete the durable consumer, confirm the running
     worker self-heals within ~30s without restart.
   - **#601**: tail worker logs around startup and confirm no
     `user:password@` strings; confirm
     `/tmp/worker_config.txt` shows `[REDACTED]@`.
   - **#602**: light verification — assert
     `_extract_agent_metadata` no longer treats an explicit
     `scopes=[]` as missing, via a quick API/python probe (this
     fix is unit-test-covered; light check is sufficient).
5. Side-by-side update of the post-deploy metrics against the
   `2026-05-23 gke-provision-validation` baseline (DB conn count,
   API latency, KEDA state).

## Phases

### Phase A — auth + context + branch awareness

1. `gcloud container clusters get-credentials noetl-cluster
   --region us-central1 --project noetl-demo-19700101` and
   confirm context resolves to
   `gke_noetl-demo-19700101_us-central1_noetl-cluster`.
2. Sync submodules:
   ```
   git -C repos/ops fetch origin && git -C repos/ops checkout main && git -C repos/ops pull origin main
   git -C repos/noetl fetch origin && git -C repos/noetl checkout main && git -C repos/noetl pull origin main
   ```
   Expected tips at or after:
   - `repos/noetl`: `69d55d40` (v2.100.5 release; PR #602 merged).
   - `repos/ops`: `4b7fc46` (PR #114 — `reset`/retry/Ready-pod
     targeting in the dev playbook).
3. Record current Helm release state:
   ```
   helm list -n noetl
   kubectl get deploy -n noetl -o jsonpath='{range .items[*]}{.metadata.name} image={.spec.template.spec.containers[0].image}{"\n"}{end}'
   ```
   Save the **current image tag** so rollback is trivial. Expected
   pre-deploy: `pftlog-e3db3624-20260521115509` per the previous
   round.

### Phase B — image build + push

4. The canonical build path lives in
   `repos/ops/automation/gcp_gke/noetl_gke_fresh_stack.yaml`
   (around line 548) and uses Cloud Build:
   ```
   gcloud builds submit "$NOETL_REPO" \
     --config "$NOETL_REPO/docker/noetl/cloudbuild.yaml" \
     --substitutions=_IMAGE="$NOETL_IMAGE":v2.100.5
   ```
   where `$NOETL_REPO` is the path to `repos/noetl` and
   `$NOETL_IMAGE` is
   `us-central1-docker.pkg.dev/noetl-demo-19700101/noetl/noetl`.
   Run that one step (do not run the full `provision` action of
   the playbook — that would re-create more than we want).
5. Alternative: local Docker build + push:
   ```
   gcloud auth configure-docker us-central1-docker.pkg.dev
   docker build \
     -f repos/noetl/docker/noetl/dev/Dockerfile \
     -t us-central1-docker.pkg.dev/noetl-demo-19700101/noetl/noetl:v2.100.5 \
     repos/noetl
   docker push us-central1-docker.pkg.dev/noetl-demo-19700101/noetl/noetl:v2.100.5
   ```
   Pick whichever path your environment is set up for. Cloud Build
   is preferred — it bypasses local docker daemon size issues.
6. Confirm the tag landed:
   ```
   gcloud artifacts docker images list us-central1-docker.pkg.dev/noetl-demo-19700101/noetl/noetl \
     --filter="tags:v2.100.5" --limit=1
   ```

### Phase C — Helm upgrade

7. The deployed Helm chart lives at
   `repos/ops/automation/helm/noetl/`. The image is parameterized
   via `image.repository` + `image.tag`. The recorded values used
   on the live cluster come from the playbook section
   (`noetl_gke_fresh_stack.yaml` line ~1468). Reuse them; only
   change the image tag.
8. Run the minimal upgrade:
   ```
   cd repos/ops
   helm upgrade --install noetl ./automation/helm/noetl \
     --namespace noetl \
     --reuse-values \
     --set image.tag=v2.100.5
   ```
   Important: `--reuse-values` preserves every other override
   (server replicas, worker autoscaling, ingress, persistence,
   etc.) from the previous deploy. We only want to swap the
   image tag.
9. Watch the rollout:
   ```
   kubectl rollout status deployment/noetl-server -n noetl --timeout=300s
   kubectl rollout status deployment/noetl-worker -n noetl --timeout=300s
   ```
10. Confirm the new image is running on every pod:
    ```
    kubectl get pods -n noetl -o jsonpath='{range .items[*]}{.metadata.name} {.spec.containers[0].image}{"\n"}{end}'
    ```
    Every line should end in `:v2.100.5`.

### Phase D — verify the three fixes

11. **#601 — credential redaction.** Tail a fresh worker's
    startup logs and confirm no leaked credentials:
    ```
    POD=$(kubectl get pod -n noetl -l app=noetl-worker -o jsonpath='{.items[0].metadata.name}')
    kubectl logs -n noetl "$POD" | grep -E "NATS|Starting Core worker" | head -10
    ```
    Expected: every URL appears as
    `nats://[REDACTED]@nats:4222` (or similar — depends on
    Helm release's NATS user config). No `user:password@` strings.
    Also check the in-pod debug file:
    ```
    kubectl exec -n noetl "$POD" -- cat /tmp/worker_config.txt
    ```
    `NATS URL: nats://[REDACTED]@...`.

12. **#600 — consumer drift self-heal.** Test by removing the
    durable consumer and watching the running worker recover
    **without a restart**:
    ```
    kubectl exec -n nats deploy/nats-box -- nats --server nats://<creds>@nats:4222 \
      consumer rm NOETL_COMMANDS noetl_worker_pool --force
    sleep 5
    kubectl exec -n nats deploy/nats-box -- nats --server nats://<creds>@nats:4222 \
      consumer ls NOETL_COMMANDS
    # → no consumer
    sleep 60   # give the rate-limited recovery a window to fire (30s gate + fetch retry)
    kubectl exec -n nats deploy/nats-box -- nats --server nats://<creds>@nats:4222 \
      consumer ls NOETL_COMMANDS
    # → noetl_worker_pool back, recreated by the running worker
    ```
    Confirm via `consumer info` that `Max Ack Pending: 64`,
    `Ack Wait: 15m30s`, `Max Deliveries: 1000` — same shape as
    the worker code creates at startup. Also confirm the same
    worker pod (no restart) is the owner:
    ```
    kubectl get pod -n noetl -l app=noetl-worker -o jsonpath='{.items[*].status.containerStatuses[0].restartCount}'
    ```
    All zero. **Restart count not incrementing is the
    load-bearing evidence** that the self-heal happened in-flight.

13. **#602 — catalog scope semantic fix.** Quick Python check
    against the live noetl-server (via port-forward):
    ```
    kubectl port-forward -n noetl svc/noetl 18082:8082 &
    sleep 3
    # Register a tiny test agent with explicit empty scopes, then
    # list and assert terminal_scopes survived as []
    ```
    Or — simpler — confirm the deployed image actually has the
    fix by exec'ing into a pod and grepping the source:
    ```
    kubectl exec -n noetl "$POD" -- /bin/sh -c \
      'grep -A2 "if \"scopes\" in terminal" /app/noetl/server/api/catalog/service.py'
    ```
    If that match is present, the fix is in the deployed image.
    Light verification is fine — unit tests in
    `tests/api/test_catalog_agent_filters.py` already cover the
    behavior.

### Phase E — regression smoke

14. Repeat the 5× `test/simple_python` execution timing from the
    previous round. If `test/simple_python` is still in the
    catalog from your prior session, reuse it; otherwise re-
    register it from `repos/e2e/fixtures/playbooks/simple_python.yaml`.
    Capture all 5 durations.

15. Capture DB connection footprint (this cluster uses Cloud SQL
    + PgBouncer; per-pod client_addr breakdown isn't available
    in the way local kind exposes it — record whatever
    `pg_stat_activity` does report):
    ```
    kubectl exec -n postgres deploy/pgbouncer -- /bin/sh -c '...'
    ```
    Or skip if PgBouncer doesn't expose stats; note the limitation
    in the report.

16. Capture KEDA state — `ScaledObject` should still be `READY=True`
    and `ACTIVE=False` once the backlog drains. Confirm the
    earlier live patches (account=`$G`,
    `natsServerMonitoringEndpoint: nats-headless...`) persist
    across the new deploy.

### Phase F — write the result

17. Write `round-01-result.md` with one H2 per Phase A–E plus
    `## Issues observed` and `## Manual escalation needed`.
    Include verbatim:
    - Pre-deploy image tag (for rollback reference).
    - Post-deploy image tag confirmed on every pod.
    - The three fix-verification command outputs (credentials
      redacted, consumer recreated without pod restart, source
      grep match).
    - Side-by-side latency / DB conn / KEDA state vs. the
      previous round's metrics.
    - Whether the manually-created consumer from the previous
      round was preserved or recreated by the new worker code.

18. Commit + push the result and any new follow-up handoffs.

## Hard rules

- **Do not run `noetl_gke_fresh_stack.yaml --set
  action=provision` end-to-end.** That re-creates infrastructure
  we don't want recreated. Use a targeted `helm upgrade
  --reuse-values --set image.tag=v2.100.5` instead.
- **Do not delete or modify the existing manually-created
  `noetl_worker_pool` consumer before Phase D.** The drift test
  in Phase D deletes it intentionally; we want to observe the
  fix path. (After Phase D it'll be recreated by the running
  worker, which IS the test.)
- **Do not push any PRs as part of this round.** This is a
  deploy + verify round. If the deploy surfaces a bug that needs
  a code fix, open a separate handoff or PR.
- **No secrets in any file under ai-meta.** Redact NATS URLs in
  the report; don't paste GCP service account JSON.
- **No force-push.**

## What success looks like

- All `noetl-server` + `noetl-worker` pods Running on the
  `:v2.100.5` image.
- Worker logs and `/tmp/worker_config.txt` show no
  `user:password@` strings.
- Consumer drift test passed: delete consumer → wait ~30s →
  consumer recreated by the running worker (pod restart count
  unchanged).
- 5 `test/simple_python` executions succeed; warm steady-state
  latency comparable to or better than the previous round
  (~1.0s).
- A reproducible result file that the next agent (or human)
  can use to roll forward to v2.101.x and beyond.

## Rollback (only if Phase C or D fails catastrophically)

```
helm upgrade noetl ./automation/helm/noetl \
  --namespace noetl \
  --reuse-values \
  --set image.tag=<previous-tag>     # captured in Phase A.3
```

That single command reverts the image. Don't roll back unless
the new image fails to start at all — graceful degradation +
in-flight reporting is preferable to a fast rollback.
