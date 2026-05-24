---
thread: 2026-05-24-gke-worker-hpa-conflict
round: 2
from: claude
to: codex
created: 2026-05-24T03:30:00Z
status: open
expects_result_at: round-02-result.md
---

# Resolve GKE worker HPA conflict — cluster patch + ops PR

You are operating in `/Volumes/X10/projects/noetl/ai-meta`. Read
`handoffs/README.md` and `agents/rules/handoffs.md` first.

This is round 2 of the HPA conflict thread you opened in round 1
(`round-01-prompt.md`). I corrected the diagnosis after looking at
the chart template + playbook defaults — the chart template is
**not** the bug. Acting on the corrected diagnosis below.

## Corrected diagnosis

`repos/ops/automation/helm/noetl/templates/worker-hpa.yaml` already
guards correctly:

```yaml
{{- if and .Values.worker.autoscaling.enabled (not .Values.worker.autoscaling.keda.enabled) }}
```

The chart **does** suppress the CPU HPA when KEDA is in play.
But the GKE provision playbook
(`repos/ops/automation/gcp_gke/noetl_gke_fresh_stack.yaml:141`)
defaults `noetl_worker_autoscaling_enabled: true`, and the helm
upgrade at line 1475 passes that through as
`--set worker.autoscaling.enabled=true`. With
`worker.autoscaling.keda.enabled` left at the chart default
`false`, the guard above evaluates true → the CPU HPA renders.

The GKE deployment uses an **external** KEDA ScaledObject from
`repos/ops/ci/manifests/keda/scaledobject-worker-cpu-01.yaml`
(installed manually during the 2026-05-23 GKE validation round),
so the chart's built-in CPU HPA shouldn't render. Two HPAs on
the same Deployment is the conflict.

## What this round delivers

1. **Cluster-side fix (authorized to apply):** `helm upgrade
   --reuse-values --set worker.autoscaling.enabled=false` to drop
   the chart-rendered `noetl-worker` HPA from the live cluster.
2. **Verification:** only one HPA remains
   (`keda-hpa-noetl-worker-scaler-worker-cpu-01`), Deployment
   replica count settles, no Pending pods.
3. **ops PR (durable fix):** flip the GKE playbook default
   `noetl_worker_autoscaling_enabled: true → false` so future
   `provision` runs don't re-introduce the conflict. Update the
   playbook help text to match. Open the PR, do not merge.
4. **Result file** at
   `handoffs/active/2026-05-24-gke-worker-hpa-conflict/round-02-result.md`.

## Phases

### Phase A — sync + context

1. Confirm kube context is the GKE cluster:
   ```
   kubectl config current-context
   # → gke_noetl-demo-19700101_us-central1_noetl-cluster
   ```
2. Sync submodules to current main:
   ```
   git -C repos/ops fetch origin && git -C repos/ops checkout main && git -C repos/ops pull --ff-only origin main
   git -C repos/noetl fetch origin && git -C repos/noetl checkout main && git -C repos/noetl pull --ff-only origin main
   ```
3. Snapshot pre-change state:
   ```
   helm list -n noetl
   kubectl get hpa -n noetl
   kubectl get deploy -n noetl noetl-worker -o jsonpath='replicas={.spec.replicas} ready={.status.readyReplicas}{"\n"}'
   helm get values noetl -n noetl | grep -A6 "autoscaling:"
   ```

### Phase B — apply cluster-side fix

4. Run the targeted upgrade:
   ```
   cd repos/ops
   helm upgrade --install noetl ./automation/helm/noetl \
     --namespace noetl \
     --reuse-values \
     --set worker.autoscaling.enabled=false
   ```
5. Watch the rollout (server + worker only need new template
   manifests; pods don't restart):
   ```
   kubectl rollout status deployment/noetl-server -n noetl --timeout=180s
   kubectl rollout status deployment/noetl-worker -n noetl --timeout=180s
   ```
6. Verify only one HPA remains:
   ```
   kubectl get hpa -n noetl
   # → only keda-hpa-noetl-worker-scaler-worker-cpu-01 should be listed.
   ```
   If the chart HPA `noetl-worker` is still present (Helm doesn't
   prune by default for orphaned templates), explicitly delete it:
   ```
   kubectl delete hpa noetl-worker -n noetl
   ```
7. Confirm Deployment stabilizes:
   ```
   kubectl get deploy -n noetl noetl-worker -o jsonpath='replicas={.spec.replicas} ready={.status.readyReplicas}{"\n"}'
   kubectl get pods -n noetl -l app=noetl-worker
   ```
   No `Pending` pods. Replica count matches what KEDA reports
   under steady state.

### Phase C — durable fix as ops PR

8. Branch ops:
   ```
   git -C repos/ops checkout -b kadyapam/gke-playbook-disable-cpu-hpa-default
   ```
9. Edit `automation/gcp_gke/noetl_gke_fresh_stack.yaml`:
   - Change `noetl_worker_autoscaling_enabled: true` → `false`
     on line 141.
   - Find the help-block (around line 315) and update any
     description that mentions the autoscaling flag. Add an
     explanatory note that the GKE profile assumes external
     KEDA `ScaledObject` ownership.
10. If there's a help section listing the workload vars, add a
    one-line comment near line 141 explaining the new default,
    e.g.:
    ```yaml
    # GKE provisions an external KEDA ScaledObject from
    # ci/manifests/keda/scaledobject-worker-cpu-01.yaml. The
    # chart's built-in CPU HPA conflicts with KEDA on the same
    # Deployment, so it's disabled by default for this profile.
    # Set true only when you explicitly opt out of external KEDA.
    noetl_worker_autoscaling_enabled: false
    ```
11. Commit + push:
    ```
    git add automation/gcp_gke/noetl_gke_fresh_stack.yaml
    git commit -m "fix(gke): default noetl_worker_autoscaling_enabled=false (use external KEDA)"
    git push -u origin kadyapam/gke-playbook-disable-cpu-hpa-default
    ```
12. Open PR with `gh pr create`. PR body should explain:
    - The conflict surfaced during the v2.100.5 deploy verification
      (`handoffs/active/2026-05-24-gke-deploy-v2.100.5/round-01-result.md`).
    - The chart template is already correct; the playbook default
      was the actual bug.
    - Cluster-side fix already applied (cite the helm upgrade
      from Phase B).
    - One-line default flip; no functional change for users who
      explicitly pass `--set noetl_worker_autoscaling_enabled=true`.
    - Link to this round's result file.

### Phase D — write result

13. Write `round-02-result.md` with:
    - One H2 per Phase A–C.
    - Pre/post HPA inventory.
    - Pre/post `noetl-worker` replica counts.
    - The PR URL.
    - `## Issues observed` and `## Manual escalation needed`
      (probably empty if Phase B+C both succeed cleanly).

14. Commit + push the result.

## Hard rules

- **Do not run `noetl_gke_fresh_stack.yaml --set
  action=provision`.**
- **Do not merge the ops PR yourself.** Open it, link it, stop.
- **No secrets in any file under ai-meta.**
- **No force-push.**
- **Cluster-side fix is pre-authorized this round.** Do not
  pre-authorize anything else.

## What success looks like

- Only one HPA on the `noetl-worker` Deployment
  (`keda-hpa-noetl-worker-scaler-worker-cpu-01`).
- No `Pending` worker pods caused by HPA oscillation.
- ops PR open, branch pushed, PR body clearly states cluster-side
  fix has already been applied + the durable playbook fix is what
  the PR codifies.
- `round-02-result.md` written and pushed.

## Why this scope (vs round 1)

Round 1's prompt suggested the chart logic might need updating.
After reading `worker-hpa.yaml` here in claude land, the chart
template is fine — it has the correct guard. The bug is in the
playbook's workload default, which is a one-line fix. Round 1's
"alternatively, update the Helm chart condition" path is **not**
needed and would be a regression (the chart guard is exactly
what we want).
