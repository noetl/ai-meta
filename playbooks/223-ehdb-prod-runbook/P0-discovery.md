# P0 — read-only prod discovery

**Run 2026-08-03 against `shastaratech-noetl-prod`. Read-only: no writes, no
applies, no `kubectl` mutations. The only state changed was the local
kubeconfig (`get-credentials`).**

Identity confirmed before anything else, because a wrong active account fails
looking exactly like a policy denial (ai-meta#204):

```
account  shastaratech@gmail.com          (gcloud auth list → active)
project  shastaratech-noetl-prod         (986938120811, ACTIVE)
cluster  noetl-prod-autopilot us-central1 RUNNING 1.35.6-gke.1250000
context  gke_shastaratech-noetl-prod_us-central1_noetl-prod-autopilot
```

The shell default project was `shastara`; every call was scoped with
`CLOUDSDK_CORE_PROJECT` + `CLOUDSDK_CORE_ACCOUNT` rather than by mutating
`gcloud config`.

---

## Discovery table

| Fact | Expected (runbook) | **Observed** | |
| :-- | :-- | :-- | :-- |
| Context | `gke_..._noetl-prod-autopilot` | exact match | ✅ |
| server image | v3.60.2 | `server-rust:v3.60.2` @ `sha256:e878522248ea7cdff1f7562124d1863572381a92a0c6c3b1c81b3e550941d79e` | ✅ |
| worker image | v5.91.2 | `noetl-worker-rust:v5.91.2` @ `sha256:0d1866feafb79adcb9c6f80939572edf0d0bbc03da76ea7258e94d6e41ee83cb` | ✅ |
| gateway image | v3.7.1 | `noetl-gateway:v3.7.1` @ `sha256:9a3d1a66ae1e801e6f8dbb340f6d9e2fe8aa9f1d03bdf7fa7ccf125e5962b719` — **ns `gateway`, not `noetl`** | ⚠ |
| Writer workload | Deployment `noetl-cmdbus-writer-0` | Deployment `noetl-cmdbus-writer-0`, 1/1, container `noetl-worker` | ✅ |
| Writer `strategy.type` | `Recreate` | `Recreate` | ✅ |
| Writer grace period | ≥ 30 | **90** (IaC StatefulSet sets 60 → a reduction, still ≫ the 15 s seal budget) | ⚠ |
| Writer PVC names | `noetl-cmdbus-writer-data`, `noetl-eventbus-writer-data`, `noetl-eventbus-kv-data` | **`noetl-cmdbus-writer-0-data`, `noetl-eventbus-writer-0-data`, `noetl-eventbus-kv-0-data`** — all three differ | ❌ |
| PVC storage class | `premium-rwo` | `premium-rwo`, all four Bound (20Gi / 50Gi / 20Gi / 20Gi) | ✅ |
| `NOETL_COMMAND_BUS` / `NOETL_EVENT_BUS` | `ehdb` / `ehdb` | `ehdb` / `ehdb` | ✅ |
| NATS gone | no namespaces, health `"removed"` | no `nats*` namespaces; `/api/health` → `{"status":"ok","database":"connected","nats":"removed","version":"3.60.2"}` | ✅ |
| `NOETL_EVENT_INGEST_PUBLISH_ONLY` | `true` | `true` | ✅ |
| `NOETL_MATERIALIZER_ENABLED` / `_SOURCE` | true / `ehdb` | `true` / `ehdb` | ✅ |
| `NOETL_RESULT_MATERIALIZER_ENABLED` / `_SOURCE` | true / `ehdb` | `true` / `ehdb` (+ `NOETL_RESULT_MINT_AUTHORITATIVE=true`, `RESULT_TIER_DR` unset) | ✅ |
| `NOETL_STATE_SHARD_WRITE` | **false/unset (#217)** | **`true`** on both system pools | ❌ |
| `NOETL_STATE_MATERIALIZER_SOURCE` | may be unset | `ehdb` — present, and **required**, since the flag above is true | ✅ |
| `NOETL_STATE_BUILDER` / `_SHADOW` / `_SOURCE` | `server` / unset / may be unset | **`offserver`** / unset / `ehdb` (server *and* both system pools) | ❌ |
| `NOETL_FEED_FILTER_SUBJECT` per pool | shared / system | user pool `noetl.commands.shared.>`; both system pools `noetl.commands.system.>`; writer `noetl.commands.cmdbus.>` | ✅ |
| ScaledObject | "uncertain — was paused with a nats trigger" | **`noetl-worker-rust`, NOT paused, Ready=True**, single `metrics-api` trigger on `http://noetl-cmdbus-writer-0…:9102/metrics`, `valueLocation=ehdb_feed_subject_lag{subject="commands.shared.shard.0"}`, min 2 / max 20 / target 2. **No NATS trigger.** | ❌ (better) |
| HPA present? | **no**, if the SO is paused | **yes** — `keda-hpa-noetl-worker-rust`, age 3d11h, `0/2 (avg)`, 2 replicas | ❌ (better) |
| Monitoring CRD | `PodMonitoring` (GMP) | `podmonitorings` + `clusterpodmonitorings` (GMP). One object: `noetl-cmdbus-writer`, scraping ports `cmdbus-lag` (9102) and `metrics` (9090) | ⚠ |
| Shard count | 1 | `NOETL_COMMAND_SHARD_COUNT=1`, `NOETL_EVENT_SHARD_COUNT=1` | ✅ |

### Live bus health at time of reading

```
:9102  ehdb_feed_shard_committed{shard="0"}                     39116
       ehdb_feed_shard_lag{shard="0"}                               0
       ehdb_feed_subject_lag{subject="commands.shared.shard.0"}     0
       ehdb_feed_subject_lag{subject="commands.system.shard.0"}     0
       ehdb_feed_shard_resume_from{shard="0",origin="persisted"} 38573
       ehdb_feed_shard_resume_stored{shard="0",clamped="false"}  38573
       ehdb_l0_out_of_order_appends                                 0
:9106  ehdb_events_cursor_errors                                    0
       ehdb_events_group_committed{noetl_materializer}           4022  lag 0
       ehdb_events_group_committed{noetl_result_materializer}    4022  lag 0
       ehdb_events_group_committed{noetl_state_materializer}     4022  lag 0
```

Faces: all ten ports listening (9090, 9100–9108), read from the pod's own
`netstat -ltn`. **No connect was made to 9104 / 9107 / 9108** (ehdb#311).

Writer resources: requests 250m / 512Mi, limits 2 CPU / 4Gi.
ServiceAccount `noetl-worker`. Env var count 31.

---

## The fail-loud precondition — **SATISFIED**

Every enabled consumer already carries its `_SOURCE`, spelled `ehdb`, on both
system pools (`noetl-worker-system-pool`, `noetl-worker-system-pool-shard1`):

| Consumer | Enable flag | Source var | |
| :-- | :-- | :-- | :-- |
| materializer | `NOETL_MATERIALIZER_ENABLED=true` | `NOETL_MATERIALIZER_SOURCE=ehdb` | ✅ |
| result materializer | `NOETL_RESULT_MATERIALIZER_ENABLED=true`, `NOETL_RESULT_MINT_AUTHORITATIVE=true` | `NOETL_RESULT_MATERIALIZER_SOURCE=ehdb` | ✅ |
| state materializer | `NOETL_STATE_SHARD_WRITE=true` | `NOETL_STATE_MATERIALIZER_SOURCE=ehdb` | ✅ |
| state builder | `NOETL_STATE_BUILDER=offserver` | `NOETL_STATE_BUILDER_SOURCE=ehdb` | ✅ |

The user pool and the writer enable none of the four, so they demand nothing.
**No `kubectl set env` remedy is needed. P1 will not crashloop on this.**

One caveat: `noetl-cmdbus-writer-1` (scaled to 0) still carries
`NOETL_COMMAND_BUS=nats`. It cannot start, so it is inert — but it is a live
`nats` value on a platform whose NATS code paths are deleted, and it would fail
on the new image if anyone ever scaled it up. Debris; see below.

---

## Findings that change the runbook

### 1. The three `claim_*` PVC names are all wrong in the IaC — ❌ blocker, **fixed**

Every one of the IaC's defaults differs from prod (shard-indexed in reality),
and `--set` on the entry point was silently discarded, so no override could
reach the child. A converge would have mounted non-existent claims and
stranded the live command and event logs. Fixed in ops@`9dcc5dd`.

### 2. `NOETL_STATE_BUILDER=offserver` in prod, not `server` — ❌ **unresolved, P3/P4 blocker**

The runbook, the playbook comments and ai-meta#217 all assert prod runs
`server` with the off-server subsystem disabled. It does not: the server and
both system pools run `offserver` with `NOETL_STATE_BUILDER_SOURCE=ehdb`, and
the system pools hold a live `:9108` WAL client
(`NOETL_EVENT_BUS_WAL_ADDR=…:9108`).

`ehdb_runtime.yaml` defaults `state_builder: server` and the runbook's P3/P4
command **does not pass it**. A converge as written would flip a running
subsystem off. The parameter *is* threaded, so the fix is one `--set` —
but it has to be added to the P3/P4 command lines:

```
--set state_builder=offserver
```

Left as a flag rather than a default change, because flipping the default
changes behaviour for every caller including kind.

### 3. Prod runs all THREE materializer groups — ❌ premise inverted

`NOETL_STATE_SHARD_WRITE=true` on both system pools, and `:9106` shows
`noetl_state_materializer` live at cursor 4022, lag 0, alongside the other two.

Consequences, all opposite to the runbook's P3 gap 2:

- The IaC's `state_shard_write: "true"` default is **correct** for prod. There
  is no "silent topology change smuggled in by the IaC" to prevent.
- `verify_groups`' default (all three groups) is **correct** for prod. The
  runbook's instruction to narrow it to two groups would have made verify
  read a *live* group as absent.
- The threading gap was still real and is fixed (ops@`9dcc5dd`), so the
  parameter is now controllable in both directions.

### 4. The autoscaler is already converged and running — ❌ premise stale, P4c largely done

The ScaledObject is **not paused**, carries exactly one `metrics-api` trigger
on the EHDB per-subject lag, has no NATS trigger, and its HPA
(`keda-hpa-noetl-worker-rust`) has existed for 3d11h. That is precisely what
P4c's command would render.

So "the user pool has had no autoscaling since 2026-07-26" (ai-meta#210) is no
longer true — it was restored around 2026-07-31, after the runbook's source
notes were written. P4c drops from "live change to replica counts" to an
idempotence check. The #210 signature (absent HPA) is not present.

### 5. The gateway is in namespace `gateway`, not `noetl` — ⚠ P3/P4 needs two more `--set`s

| Param | IaC default | Prod |
| :-- | :-- | :-- |
| `gateway_namespace` | `noetl` | `gateway` |
| `gateway_deployment` | `noetl-gateway` | `gateway` |
| `gateway_container` | `gateway` | `gateway` ✅ |

With `gateway_reconcile=true` ("fail if it does not exist") the P3/P4 command
as written will **fail** — or, at `auto`, silently skip the gateway. Both
params are threaded, so:

```
--set gateway_namespace=gateway --set gateway_deployment=gateway
```

The gateway's EHDB wiring is otherwise correct and needs no change:
`NOETL_EVENT_SOURCE=ehdb`, `NOETL_EVENT_FEED_ADDR=…:9105`, `NOETL_KV_ADDR=…:9107`.

### 6. The user pool's container is `noetl-worker`, not `worker` — ⚠ one more `--set`

Every worker container in prod is named `noetl-worker`, including
`noetl-worker-rust`. `ehdb_runtime.yaml` defaults `user_pool_container: worker`.
Threaded, so:

```
--set user_pool_container=noetl-worker
```

This is the same class as the runbook's existing "target containers by name,
never `*`" warning. Note the `wait-for-api` init container
(`curlimages/curl:8.7.1`) is present on the writer and both system pools, so
that warning applies to the writer too.

### 7. A dormant shard-1 writer exists — ⚠ debris, not a blocker

`noetl-cmdbus-writer-1` (Deployment, replicas 0, `NOETL_COMMAND_BUS=nats`,
grace 30, cmdbus PVC only) plus Service `noetl-cmdbus-writer-1` and PVC
`noetl-cmdbus-writer-1-data` (20Gi, Bound). At `shard_count=1` the IaC's
`drain_legacy` loop only walks ordinal 0, so this is left untouched — it keeps
holding a 20Gi PD and a stale `nats` value.

Also: `noetl-worker-system-pool-shard1` is running 1/1 but claims from
**writer-0** on the *same* subject as `noetl-worker-system-pool`. It is a
second replica of the system pool, not a shard-1 pool. Naming only.

### 8. `:9106` is not scraped by GMP — ⚠ affects P2

The single `PodMonitoring` scrapes `cmdbus-lag` (9102) and `metrics` (9090)
only. The events face `:9106` — which carries `ehdb_events_cursor_errors` and
all three `ehdb_events_group_*` series — is **not** in Google Managed
Prometheus. P2's gate on `cursor_errors == 0` and on group-cursor advance
cannot be met from GMP; it needs the in-cluster P2a sampler, which is what the
runbook already prescribes. Worth knowing that there is no historical series
to compare against for prod's earlier 26 `cursor_errors` (ai-meta#216).

### 9. Writer probes and memory limit move under converge — ⚠ read before P4

- Prod's writer probes are `tcpSocket :9090` (metrics). The IaC renders
  readiness **and** liveness as `tcpSocket` on `cmdbus-claim` (**:9101**). The
  playbook documents this as verified-safe (":9101 does not share that shape
  and tolerates the probe — verified over a full rollout of 5s periods"), but
  it is a move from a plain HTTP port onto a bus face. Deliberate, documented,
  flagged here so it is not a surprise in the P3 diff.
- Writer memory limit would go **4Gi → 2Gi** (`writer_memory_limit` default).
  Pass `--set writer_memory_limit=4Gi` to hold prod's current headroom.
- Grace period would go **90 → 60**. Still ≫ the 15 s seal budget; acceptable.

---

## Corrected P3/P4 command line

Everything above folded in. Additions to the runbook's version are marked `←`.

```bash
noetl run automation/ehdb/ehdb_platform.yaml -r local \
  --set action=plan \
  --set profile=prod \
  --set context=gke_shastaratech-noetl-prod_us-central1_noetl-prod-autopilot \
  --set writer_storage_mode=claim \
  --set writer_storage_class=premium-rwo \
  --set writer_image="$WORKER_IMG" \
  --set writer_image_pull_policy=IfNotPresent \
  --set writer_memory_limit=4Gi \                    # ← was 2Gi, prod runs 4Gi
  --set state_builder=offserver \                    # ← prod is offserver, NOT server
  --set state_builder_shadow=false \
  --set state_shard_write=true \                     # ← now actually threaded
  --set user_pool_container=noetl-worker \           # ← default `worker` is wrong
  --set gateway_reconcile=true \
  --set gateway_namespace=gateway \                  # ← gateway is not in ns noetl
  --set gateway_deployment=gateway \                 # ←
  --set autoscaler_enabled=false
```

`verify_groups` needs **no** override — the default (all three groups) is
correct for prod. The three `claim_*` names now default to prod's real ones
and are forwarded, so they need no override either; verify them in the plan
diff regardless.

## Rollback targets recorded for P1

```
PREV_WORKER=us-central1-docker.pkg.dev/shastaratech-noetl-prod/noetl/noetl-worker-rust@sha256:0d1866feafb79adcb9c6f80939572edf0d0bbc03da76ea7258e94d6e41ee83cb
PREV_SERVER=us-central1-docker.pkg.dev/shastaratech-noetl-prod/noetl/server-rust@sha256:e878522248ea7cdff1f7562124d1863572381a92a0c6c3b1c81b3e550941d79e
PREV_GATEWAY=us-central1-docker.pkg.dev/shastaratech-noetl-prod/noetl/noetl-gateway@sha256:9a3d1a66ae1e801e6f8dbb340f6d9e2fe8aa9f1d03bdf7fa7ccf125e5962b719
```

Container name for every `set image` on a worker workload: `noetl-worker`.

## Gate

The runbook's P0 gate is **met**: the context is exact, the PVC names are
recorded verbatim, and the fail-loud matrix has no enabled-consumer-without-a-
source row.

Two findings block later phases and are *not* worked around here — finding 2
(`state_builder=offserver`) and findings 5/6 (gateway location, user-pool
container name) must be added to the P3/P4 command line before P4 runs. The
corrected command above does that; it has not been executed.
