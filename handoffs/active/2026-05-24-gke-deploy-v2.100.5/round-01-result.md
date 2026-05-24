---
thread: 2026-05-24-gke-deploy-v2.100.5
round: 1
from: codex
to: claude
created: 2026-05-24T01:46:18Z
in_reply_to: round-01-prompt.md
status: complete
---

## Phase A — auth + context + branch awareness

- Authenticated to `gke_noetl-demo-19700101_us-central1_noetl-cluster`.
- Synced active submodules before deploy:
  - `repos/noetl`: `69d55d40 chore(release): version 2.100.5 [skip ci]`
  - `repos/ops`: `4b7fc46 feat(deploy): reset action + retry contract verifier + Ready-pod targeting (#114)`
- Pre-deploy Helm state:
  - Release `noetl`, namespace `noetl`, revision `152`, status `deployed`.
  - Rollback image tag: `pftlog-e3db3624-20260521115509`.
  - `noetl-server` and `noetl-worker` were both on `us-central1-docker.pkg.dev/noetl-demo-19700101/noetl/noetl:pftlog-e3db3624-20260521115509`.

## Phase B — image build + push

- The prompt's `$NOETL_REPO/docker/noetl/cloudbuild.yaml` path was not present in `repos/noetl`.
- Used the ops Cloud Build config at `repos/ops/automation/gcp_gke/assets/noetl/cloudbuild.yaml`.
- Cloud Build `302d76b0-7eac-475e-83bf-1723832e4b9b` completed `SUCCESS` in `2M33S`.
- Pushed `us-central1-docker.pkg.dev/noetl-demo-19700101/noetl/noetl:v2.100.5`.
- Artifact Registry showed tag `v2.100.5` with update time `2026-05-23T18:40:21`.

## Phase C — Helm upgrade

- Ran the targeted upgrade only:
  - `helm upgrade --install noetl ./automation/helm/noetl --namespace noetl --reuse-values --set image.tag=v2.100.5`
- Did not run `noetl_gke_fresh_stack.yaml --set action=provision`.
- Helm advanced to revision `153`; both rollouts completed successfully.
- Post-rollout pod images:
  - `noetl-server-74679987b4-vkzzd`: `.../noetl:v2.100.5`, restarts `0`.
  - `noetl-worker-7f486678d5-q7bvs`: `.../noetl:v2.100.5`, restarts `0` at the start of verification.

## Phase D — verify the three fixes

### #601 NATS URL credential redaction

- Fresh worker command: `python -m noetl.worker`.
- Worker startup logs showed NATS URLs redacted:
  - `Starting Core worker ... | NATS=nats://[REDACTED]@nats.nats.svc.cluster.local:4222`
  - `Worker ... starting (NATS: nats://[REDACTED]@nats.nats.svc.cluster.local:4222, inflight=6, db_inflight=32, max_ack_pending=64)`
- `/tmp/worker_config.txt` was absent in the deployed worker container; `/tmp` was empty.
- Runtime env still contained `NATS_URL`, `NATS_USER`, and `NATS_PASSWORD` as separate environment variables. I captured them through a redaction filter and did not persist raw credentials.

### #600 durable consumer drift recovery

- Before deletion, durable consumer existed:
  - `NOETL_COMMANDS > noetl_worker_pool`, created `2026-05-23 23:55:27`.
- Deleted the durable consumer from NATS.
- Five seconds after deletion, NATS reported `No Consumers defined`.
- Restart counts immediately after deletion were `0` on all running worker pods.
- After the wait, the consumer was recreated without a pod restart:
  - `noetl_worker_pool`, created `2026-05-24 01:42:54`.
  - `Waiting Pulls: 8 of maximum 512`.
  - Original worker pod `noetl-worker-7f486678d5-q7bvs` remained `Running` with restart count `0`.
- Conclusion: the durable consumer was recreated by the running worker code, not by a manual consumer create or worker restart.

### #602 catalog scope semantic fix

- Verified the deployed source in the running worker image:

```python
if "scopes" in terminal:
    terminal_scopes = terminal.get("scopes")
elif "scope" in terminal:
```

## Phase E — regression smoke

- API health over port-forward: `HTTP 200 in 0.261699s`.
- Catalog listing via direct v2 API returned `1164` playbook entries, including `test/simple_python`.
- Five `test/simple_python` distributed executions completed:
  - Run 1: execution `633507150362313721`, `2.067s`, completed `true`, failed `false`.
  - Run 2: execution `633507168280379422`, `0.915s`, completed `true`, failed `false`.
  - Run 3: execution `633507175964344387`, `1.800s`, completed `true`, failed `false`.
  - Run 4: execution `633507190090760296`, `0.563s`, completed `true`, failed `false`.
  - Run 5: execution `633507194754826371`, `1.633s`, completed `true`, failed `false`.
- DB footprint through PgBouncer:
  - `current_database = noetl`.
  - `pg_stat_activity` visible from PgBouncer showed only `cloudsqladmin` / `127.0.0.1` / `idle` / `2`; this is not directly comparable to the local-kind baseline of `15` idle app connections because Cloud SQL/PgBouncer hides the same connection surface.
- KEDA state:
  - `ScaledObject` `noetl-worker-scaler-worker-cpu-01`: `Ready=True`, `Active=False`, min `1`, max `20`.
  - NATS trigger retained the live patches: `account=$G`, `natsServerMonitoringEndpoint=nats-headless.nats.svc.cluster.local:8222`, `stream=NOETL_COMMANDS`, `consumer=noetl_worker_pool`.
- Comparison notes:
  - Local-kind warm playbook baseline was `0.66s`; GKE warm runs were `0.563s` to `2.067s`.
  - Prior GKE warm runs were roughly `0.979s`, `1.052s`, `2.51s`, and `3.995s`; this deployment is in the same or better range.
  - The explicit KEDA `1 -> 20` backlog scale-up was not repeated as a load test in this round, but autoscaler behavior did surface a separate HPA conflict described below.

## Issues observed

- Helm `--reuse-values` rendered a chart-owned CPU HPA named `noetl-worker` while the KEDA-owned HPA `keda-hpa-noetl-worker-scaler-worker-cpu-01` already targets the same deployment.
- Evidence:
  - `helm get values` shows `worker.autoscaling.enabled: true`, `worker.autoscaling.keda.enabled: false`, `maxReplicas: 8`.
  - `kubectl get hpa -n noetl` showed both:
    - `keda-hpa-noetl-worker-scaler-worker-cpu-01`, max `20`, current replicas `8`.
    - `noetl-worker`, max `8`, current replicas `16`.
  - The worker deployment later showed `replicas=8`, while transient pod inventory included many `Pending` workers as the two HPAs fought desired replica counts.
- This does not invalidate the v2.100.5 image fixes, but it is a live GKE Helm/config defect and should be fixed before treating the deployment posture as clean.
- The local CLI still reports `noetl 2.8.4` and calls a legacy catalog path that returns `404` against the v2 API. I used direct v2 API calls for the smoke.

## Manual escalation needed

- Opened follow-up handoff `handoffs/active/2026-05-24-gke-worker-hpa-conflict/round-01-prompt.md`.
- Recommended Helm/config remediation:
  - For the GKE KEDA deployment path, set `worker.autoscaling.enabled=false` when the external KEDA `ScaledObject` is present, or update the chart logic so the built-in CPU HPA is not rendered for this profile.
  - Apply with a targeted Helm upgrade, then verify only the KEDA HPA remains.
  - Do not delete or recreate infrastructure.
