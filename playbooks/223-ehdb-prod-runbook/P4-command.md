# P4 — the exact converge command, verified against prod and ops#245

**Prepared 2026-08-04. NOT run. P4 is gated on the [#225](https://github.com/noetl/ai-meta/issues/225)
wedge being cleared and P2 actually producing numbers.**

Verified against `ops#245` at **`5e28543`** and against live
`shastaratech-noetl-prod` on 2026-08-04 02:36 UTC.

## What changed since the P0 write-up

`5e28543` ("make the IaC defaults describe prod, not the kind reconstruction")
folded every P0 correction into the playbook defaults. The P0 note said these
had to go on the command line; **they no longer do.** They are listed below as
*confirmed defaults* rather than required flags, because a value that lives in
the playbook cannot be forgotten by whoever copies the command.

| Parameter | ops#245 default | live prod | |
| :-- | :-- | :-- | :-- |
| `state_builder` | `offserver` | `offserver` | ✅ |
| `state_builder_shadow` | `false` | unset (⇒ false) | ✅ |
| `state_shard_write` | `true` | `true`, both system pools | ✅ |
| `gateway_namespace` | `gateway` | `gateway` | ✅ |
| `gateway_deployment` | `gateway` | `gateway` | ✅ |
| `gateway_container` | `gateway` | `gateway` | ✅ |
| `user_pool_container` | `noetl-worker` | `noetl-worker` | ✅ |
| `system_pool_container` | `noetl-worker` | `noetl-worker` | ✅ |
| `system_pool_deployment` | both pools | both exist | ✅ |
| `writer_memory_limit` | `4Gi` | `4Gi` | ✅ |
| `writer_memory_request` | `512Mi` | `512Mi` | ✅ |
| `writer_cpu_limit` / `_request` | `2` / `250m` | `2` / `250m` | ✅ |
| `writer_claim_cmdbus` | `noetl-cmdbus-writer-0-data` | Bound, 20Gi, premium-rwo | ✅ |
| `writer_claim_eventbus` | `noetl-eventbus-writer-0-data` | Bound, 50Gi, premium-rwo | ✅ |
| `writer_claim_kv` | `noetl-eventbus-kv-0-data` | Bound, 20Gi, premium-rwo | ✅ |
| `verify_groups` | all three | all three run | ✅ |
| `shard_count` | `1` | `NOETL_COMMAND_SHARD_COUNT=1` | ✅ |

## Still required on the command line

These defaults are kind-oriented and **must** be overridden. `writer_storage_mode`
is the dangerous one — the default `template` provisions fresh volumes and
strands the live command and event logs.

```bash
cd repos/ops    # branch feat/ehdb-only-iac (ops#245) until it merges

WORKER_IMG=us-central1-docker.pkg.dev/shastaratech-noetl-prod/noetl/noetl-worker-rust@sha256:ad1e96063bf53b44869deab2cd3afec0152b033bd7f28d528299db7b65781725

# ---- P3: plan first. Changes nothing. READ THE DIFF. ----
noetl run automation/ehdb/ehdb_platform.yaml -r local \
  --set action=plan \
  --set profile=prod \
  --set context=gke_shastaratech-noetl-prod_us-central1_noetl-prod-autopilot \
  --set writer_storage_mode=claim \
  --set writer_storage_class=premium-rwo \
  --set writer_image="$WORKER_IMG" \
  --set writer_image_pull_policy=IfNotPresent \
  --set gateway_reconcile=true \
  --set autoscaler_enabled=false

# ---- P4b: converge writer + runtime, autoscaler DEFERRED. Writer pod drops. ----
noetl run automation/ehdb/ehdb_platform.yaml -r local \
  --set action=converge \
  --set profile=prod \
  --set context=gke_shastaratech-noetl-prod_us-central1_noetl-prod-autopilot \
  --set writer_storage_mode=claim \
  --set writer_storage_class=premium-rwo \
  --set writer_image="$WORKER_IMG" \
  --set writer_image_pull_policy=IfNotPresent \
  --set gateway_reconcile=true \
  --set autoscaler_enabled=false

# ---- P4c: autoscaler, separately, so a scaling anomaly and a topology
#      anomaly cannot be confused. NOTE: prod's ScaledObject is ALREADY
#      unpaused with the correct metrics-api trigger (P0 finding #4), so this
#      should be an idempotence check, not a live change. ----
noetl run automation/ehdb/ehdb_autoscaler.yaml -r local \
  --set action=converge \
  --set context=gke_shastaratech-noetl-prod_us-central1_noetl-prod-autopilot \
  --set enabled=true --set paused=false \
  --set pool_subject="commands.shared.shard.0" \
  --set min_replicas=2 --set max_replicas=20 --set monitoring=auto
```

Why each override is still needed:

| Flag | Why |
| :-- | :-- |
| `writer_storage_mode=claim` | Default `template` provisions **fresh** volumes and strands the live logs. The single most dangerous default in the run. |
| `writer_storage_class=premium-rwo` | Default is `""`. The writer's durability posture is fsync-per-append; PD-standard puts a synced append at tens of ms. |
| `writer_image` | Default is the kind-local `localhost/noetl-worker:h5209b`. Must be the v5.92.0 **digest**, never a tag. |
| `writer_image_pull_policy=IfNotPresent` | Default `Never` is a kind convenience and will not pull on GKE. |
| `gateway_reconcile=true` | Default `auto` skips the gateway if absent; prod has one and it must be reconciled. |
| `autoscaler_enabled=false` | Splits P4c out of P4b per the runbook. |
| `profile=prod` | A guard: `prod` refuses a `kind-*` context and vice versa. |
| `context` | Belt and braces on top of `profile`. |

## Mandatory before running

- **P4a first, no exceptions** — save the rollback artefacts. `drain_legacy`
  scales and **deletes** the existing writer Deployment; the PVCs survive, the
  Deployment spec does not.

  ```bash
  mkdir -p rollback-$(date +%Y%m%d)
  K get deploy -l app=noetl-cmdbus-writer -o yaml > rollback-*/writer-deployment.yaml
  K get svc    -l app=noetl-cmdbus-writer -o yaml > rollback-*/writer-services.yaml
  K get pvc -o yaml                              > rollback-*/pvcs.yaml
  K get scaledobject -o yaml                     > rollback-*/scaledobjects.yaml
  ```

  Verify the saved Deployment YAML actually contains the writer's env block,
  ports, volumeMounts and probes before continuing. A truncated save is a
  rollback that does not work.

## Two things to expect in the diff

Both are deliberate, and neither is an error — flagged so they are not a
surprise:

1. **Probes move from `tcpSocket :9090` to `tcpSocket :9101`.** Prod currently
   probes the metrics port; the IaC probes `cmdbus-claim`. The playbook
   documents `:9101` as verified-safe against ehdb#311 ("does not share that
   shape and tolerates the probe — verified over a full rollout of 5s
   periods"), but it is a move onto a bus face.
2. **`terminationGracePeriodSeconds` 90 → 60.** Still far above the 15 s
   `NOETL_EHDB_SHUTDOWN_TIMEOUT_MS` seal budget.

## Known residue the converge will not touch

`noetl-cmdbus-writer-1` (Deployment, replicas 0, `NOETL_COMMAND_BUS=nats`), its
Service, and PVC `noetl-cmdbus-writer-1-data` (20Gi, Bound). At
`shard_count=1` the `drain_legacy` loop only walks ordinal 0, so this dormant
shard-1 writer keeps holding a PD and a stale `nats` value. Harmless today;
worth cleaning up separately.

## Gate — do not run P4 until

1. [#225](https://github.com/noetl/ai-meta/issues/225) is cleared and
   root-caused. P4b's handover deliberately drops the writer pod and depends on
   the consumers reattaching cleanly; converging onto a platform whose events
   consumers silently stop consuming makes any post-converge anomaly
   indistinguishable from that defect.
2. P2 has produced actual numbers on a healthy platform. As of now it has none.
