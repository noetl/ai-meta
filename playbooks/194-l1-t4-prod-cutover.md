# L1 T4 — EHDB command-bus prod cutover (staged, human-executed)

Companion to the wiki runbook
<https://github.com/noetl/ehdb/wiki/Runbook-L1-Command-Bus-Cutover> and
[noetl/ai-meta#194](https://github.com/noetl/ai-meta/issues/194).

**Execution model (same as #166 Phase 5):** the agent runs read-only gates
only.  Every mutation below is run by the operator.  No agent flips the
live bus.  T5 (delete NATS) is NOT part of this document.

```
CTX=gke_noetl-demo-19700101_us-central1_noetl-cluster
NS=noetl
```

---

## Part 1 — read-only pre-flight (operator runs; agent reads output)

```bash
CTX=gke_noetl-demo-19700101_us-central1_noetl-cluster
NS=noetl

echo "===== 1. live images ====="
kubectl --context $CTX -n $NS get deploy \
  noetl-server-rust noetl-worker-rust noetl-worker-system-pool \
  -o custom-columns='NAME:.metadata.name,REPLICAS:.status.replicas,IMAGE:.spec.template.spec.containers[*].image'

echo "===== 2. command-bus / bus-relevant env (expect EMPTY today) ====="
kubectl --context $CTX -n $NS get deploy \
  noetl-server-rust noetl-worker-rust noetl-worker-system-pool -o json \
| jq -r '.items[] | .metadata.name as $d
   | .spec.template.spec.containers[].env[]?
   | select(.name|test("COMMAND_BUS|SHARD|NATS_|STATE_BUILDER|PUBLISH_ONLY"))
   | "\($d)\t\(.name)=\(.value // "(from ref)")"'

echo "===== 3. writer prerequisites (expect ALL MISSING today) ====="
kubectl --context $CTX -n $NS get svc  | grep -i cmdbus || echo "NO cmdbus Service"
kubectl --context $CTX -n $NS get pvc
kubectl --context $CTX -n $NS get sc 2>/dev/null | head

echo "===== 4. autoscalers ====="
kubectl --context $CTX -n $NS get scaledobject -o custom-columns=\
'NAME:.metadata.name,TARGET:.spec.scaleTargetRef.name,MIN:.spec.minReplicaCount,MAX:.spec.maxReplicaCount,PAUSED:.metadata.annotations.autoscaling\.keda\.sh/paused'
kubectl --context $CTX -n $NS get hpa

echo "===== 5. NATS health (the baseline we cut over FROM) ====="
kubectl --context $CTX -n nats get pods -o wide
kubectl --context $CTX -n nats logs -l app.kubernetes.io/name=nats --tail=20 --since=1h | tail -20

echo "===== 6. command flow is healthy right now ====="
kubectl --context $CTX -n $NS logs deploy/noetl-worker-rust --tail=40 --since=15m | grep -i "claim\|command" | tail -20
```

Optional (needs a nats box / CLI in-cluster) — the stream + consumer baseline:

```bash
kubectl --context $CTX -n nats exec deploy/nats-box -- \
  nats stream info NOETL_COMMANDS_RUST
kubectl --context $CTX -n nats exec deploy/nats-box -- \
  nats consumer info NOETL_COMMANDS_RUST noetl_worker_rust_shared
kubectl --context $CTX -n nats exec deploy/nats-box -- \
  nats consumer info NOETL_COMMANDS_RUST noetl_worker_system_rust
```

---

## Part 2 — what the local pre-flight already established

### F1 — the released images DO carry the kind-validated command-bus code

| | released tag | command-bus code | ehdb pin | == kind-validated? |
| :-- | :-- | :-- | :-- | :-- |
| server | **v3.58.0** | `src/command_bus.rs` (`PublishRouter`), PR #281 + #282 (DNS addrs) | `fa730e0` | **yes** — kind ran server ehdb `fa730e0`, server intentionally unchanged for the subject fix |
| worker | **v5.78.0** | `src/command_bus.rs` (`EhdbCommandSource`, `spawn_writer_host`), subject filter `commands.<pool>.>` derived from `NATS_FILTER_SUBJECT`, `d1_command_subject` | `f5dd76b` | **yes** — `f5dd76b` is the subject-routing fix (finding #1) |

So no special build is needed: the ordinary released images are the
validated artefacts.  `NOETL_COMMAND_BUS` defaults to `nats`, so deploying
them changes no transport behaviour.

### F2 — prod is on OLDER images → **Step 0 is required**

Prod (per `memory/`) runs server **v3.52.0** / worker **v5.52.0**, which
contain **no** `command_bus` module at all.  Part 1 §1 confirms the live
digests.  The version jump is large and carries unrelated change
(keychain fix, EHDB phases 6-10, write-behind boundary #195-#198,
tier-command-input).  **Split it:** deploy the images with the bus flag
absent (= `nats`), bake, and only then start the shadow.  Do not bundle a
26-version worker jump with a transport cutover.

### F3 — the writer has **no manifests at all** in `repos/ops`

`repos/ops@main` contains exactly one command-bus artefact: the *paused*
`ci/manifests/keda/scaledobject-worker-ehdb-command-bus.yaml` (PR #240).
Missing, and required before any flip:

1. writer-host env on the writer pod (`NOETL_COMMAND_BUS_HOST=true`,
   `_SHARD`, `_WRITER_DIR`, `_INGEST_BIND`, `_CLAIM_BIND`,
   `_METRICS_BIND`, `_ACK_WAIT_SECS`);
2. a **PVC** for `NOETL_COMMAND_BUS_WRITER_DIR` — prod's system pool
   mounts only a `dshm` emptyDir today;
3. a **ClusterIP** Service `noetl-cmdbus-writer` (ports 9100/9101/9102);
4. a `VMServiceScrape` for :9102 so `ehdb_feed_total_lag` reaches
   VictoriaMetrics (the paused ScaledObject's own prerequisite #2).

In kind these were hand-patched.  For prod they are an ops PR, reviewed
before Step 0.

### F4 — **writer singleton hazard** (prod-only; kind could not surface it)

Topology (c) co-locates the writer in `noetl-worker-system-pool`.  In kind
that pool was a fixed 1 replica.  In prod it is KEDA-scaled
`min 1 / max 20`.  With `NOETL_COMMAND_BUS_HOST=true` on the Deployment,
a scale-up gives N pods each opening the same shard's log and each
answering ingest/claim behind one round-robin ClusterIP → split-brain
(and an RWO PVC would leave the extra pods unschedulable).

**Must-fix before Step 0.**  Either:

- **(a) preferred** — move the writer into its own single-replica
  Deployment/StatefulSet (`noetl-cmdbus-writer`) with `NOETL_COMMAND_BUS_HOST=true`
  and no consumer role; or
- **(b) minimum** — pin the system pool to `maxReplicaCount: 1` for the
  whole cutover window (both its ScaledObjects), accepting the loss of
  system-pool autoscaling.

### F5 — prod is **single-shard**, so "canary one shard" does not exist

No `NOETL_COMMAND_SHARD_COUNT` anywhere; `NOETL_EVENT_NATS_SHARD_COUNT: "1"`.
The only canary axis available is **per pool**:
`noetl-worker-rust` (`noetl.commands.shared.>` → filter `commands.shared.>`,
2-20 replicas) vs `noetl-worker-system-pool` (`noetl.commands.system.>` →
`commands.system.>`, 1 replica).

**Canary hazard:** with the server in `shadow` (publishes to both buses)
and one pool flipped to `ehdb`, that pool stops draining its NATS durable
consumer.  Pending grows, and its **active** `nats-jetstream` ScaledObject
ramps the pool to `max 20`.  Mitigation: pause the canary pool's NATS
ScaledObject for the canary window (command in Step 3).

### F6 — shadow-mode lag/disk growth is expected, not a fault

In `shadow` the workers still consume NATS, so **nothing claims from the
EHDB writer**: `ehdb_feed_total_lag` climbs monotonically and the writer
PVC grows by every command for the whole window.  Size the PVC for the
planned window and keep the EHDB ScaledObject **paused** (an active one
would read that lag and scale to max).  Gate on *parity* (0 missed /
0 spurious vs NATS), not on lag being zero.

### F7 — other prod/kind deltas

- **Storage posture.**  Kind wrote to a local-path PVC on the VM's NVMe.
  GKE PD (balanced vs SSD) changes fsync latency — the 4ms first-seen in
  T0 was posture-A fsync, not the bus.  Decide the storage class and the
  fsync-vs-group-commit posture explicitly (open go/no-go checklist item).
- **Latency baseline.**  Kind's ~800ms append→claim floor was a
  server-side artefact common to both buses.  Prod's baseline must be
  captured from live metrics **before** the flip (Step 1 gate).
- **NATS unchanged for events.**  `NOETL_COMMAND_BUS` covers commands
  only; the gateway/SPA event feed (`noetl.events.>`, T3) is untouched.
- **Manifests are stale vs live prod.**  `server-rust-deployment-prod.yaml`
  still describes the v3.39.5-era pod; #166 Phase 5 was applied live with
  `set env`.  Trust Part 1's live output, never the manifest, for
  "what is prod running".
- **#188** (plaintext `noetl:noetl` NATS cred) rides along untouched;
  it retires with T5.

---

## Part 3 — staged cutover

Every step: **(a)** operator command · **(b)** agent read-only gate ·
**(c)** pass/fail · **(d)** rollback.

### Step 0 — land the command-bus-capable images + writer (NO flag flip)

**Prereq (not a kubectl step):** an ops PR adding the writer Deployment
(F4a) + PVC + ClusterIP Service + VMServiceScrape, reviewed and merged.

**(a) operator**

```bash
# 0.1 — images only; NOETL_COMMAND_BUS stays UNSET (= nats)
kubectl --context $CTX -n $NS set image deploy/noetl-server-rust \
  noetl-server=us-central1-docker.pkg.dev/noetl-demo-19700101/noetl/server-rust:v3.58.0
kubectl --context $CTX -n $NS set image deploy/noetl-worker-rust \
  worker=us-central1-docker.pkg.dev/noetl-demo-19700101/noetl/noetl-worker-rust:v5.78.0
kubectl --context $CTX -n $NS set image deploy/noetl-worker-system-pool \
  noetl-worker=us-central1-docker.pkg.dev/noetl-demo-19700101/noetl/noetl-worker-rust:v5.78.0
kubectl --context $CTX -n $NS rollout status deploy/noetl-server-rust --timeout=5m
kubectl --context $CTX -n $NS rollout status deploy/noetl-worker-rust --timeout=5m
kubectl --context $CTX -n $NS rollout status deploy/noetl-worker-system-pool --timeout=5m

# 0.2 — writer + PVC + Service + scrape (still inert: no pod has the flag)
kubectl --context $CTX -n $NS apply -f ci/manifests/noetl/cmdbus-writer-pvc.yaml
kubectl --context $CTX -n $NS apply -f ci/manifests/noetl/cmdbus-writer-deployment.yaml
kubectl --context $CTX -n $NS apply -f ci/manifests/noetl/cmdbus-writer-service.yaml
kubectl --context $CTX -n $NS apply -f ci/manifests/noetl-scrape/vmscrape-ehdb-command-bus.yaml

# 0.3 — F4b fallback ONLY if the writer stays co-located in the system pool
# kubectl --context $CTX -n $NS patch scaledobject noetl-worker-system-pool-scaler-worker-system-pool \
#   --type merge -p '{"spec":{"maxReplicaCount":1}}'
```

**(b) agent gate** — image digests match v3.58.0/v5.78.0 on all three
deployments; pods Ready and not restarting; writer pod Running with its
PVC Bound; `ehdb_feed_total_lag` scrapeable and **0**; a real playbook
completes over NATS; no new error classes in server/worker logs.

**(c) pass** = playbook completes end-to-end over NATS on the new images,
0 CrashLoopBackOff, materializer lag flat, login path healthy.
**Bake 24h before Step 1.**

**(d) rollback** — `kubectl -n $NS rollout undo deploy/noetl-server-rust
deploy/noetl-worker-rust deploy/noetl-worker-system-pool`.

### Step 1 — capture the NATS baseline (read-only, no mutation)

**(b) agent gate** — from VictoriaMetrics over a representative window:
command dispatch p50/p95/p99, completion rate, per-pool consumer lag,
system-pool RSS/CPU.  **This is the number every later step compares to.**
No pass/fail — it defines the envelope.

### Step 2 — SHADOW (NATS authoritative, EHDB mirrored)

**(a) operator**

Every `NOETL_COMMAND_BUS_*` var (host, shard, writer dir, the three binds,
ack_wait) is already baked into the writer Deployment by
[noetl/ops#241](https://github.com/noetl/ops/pull/241) and is inert while the
mode is `nats`.  The only change here is the **mode**.

```bash
WRITER=noetl-cmdbus-writer.noetl.svc.cluster.local

kubectl --context $CTX -n $NS set env deploy/noetl-cmdbus-writer \
  NOETL_COMMAND_BUS=shadow

kubectl --context $CTX -n $NS set env deploy/noetl-server-rust \
  NOETL_COMMAND_BUS=shadow NOETL_COMMAND_SHARD_COUNT=1 \
  NOETL_COMMAND_BUS_WRITER_ADDRS="0@${WRITER}:9100"

kubectl --context $CTX -n $NS rollout status deploy/noetl-cmdbus-writer --timeout=5m
kubectl --context $CTX -n $NS rollout status deploy/noetl-server-rust  --timeout=5m
```

Workers are **not** touched — they stay on NATS.

**(b) agent gate** — server log shows the writer connected **by DNS name**
(no IP literal, finding #2); every command that hits NATS also appears in
the EHDB feed (0 missed / 0 spurious) over the window;
`ehdb_feed_total_lag` climbs monotonically (**expected**, F6);
writer PVC usage tracks the projected rate with headroom; command
completion rate and p99 unchanged vs Step 1; EHDB ScaledObject still
`paused=true`; **writer pod RSS + CPU flat, not climbing with the window**
(`ClaimCoordinator::lag()` materialises the whole undelivered backlog every
2s — O(backlog) — so a rising CPU floor means the window has run long
enough and should be cut short).

**(c) pass** = 0 divergence, no server-side latency regression, PVC
headroom sufficient.  Soak **24-48h**.
**Fail** = any missed/spurious command, any p99 regression attributable to
the mirror publish, or PVC growth outside projection.

**(d) rollback**

```bash
kubectl --context $CTX -n $NS set env deploy/noetl-server-rust NOETL_COMMAND_BUS=nats
kubectl --context $CTX -n $NS rollout restart deploy/noetl-server-rust
```

### Step 3 — CANARY: one pool on `ehdb` (server stays `shadow`)

Canary the **user pool** (`noetl-worker-rust`) — the higher-volume, lower-blast-radius
one; the system pool carries the drive + materializer and goes last.

**(a) operator**

```bash
# 3.0 — MANDATORY (F5): stop the NATS scaler from chasing an undrained consumer
kubectl --context $CTX -n $NS annotate scaledobject noetl-worker-rust \
  autoscaling.keda.sh/paused="true" --overwrite

# 3.1 — flip the user pool onto the EHDB bus
kubectl --context $CTX -n $NS set env deploy/noetl-worker-rust \
  NOETL_COMMAND_BUS=ehdb NOETL_COMMAND_SHARD_COUNT=1 \
  NOETL_COMMAND_BUS_CLAIM_ADDR=noetl-cmdbus-writer.noetl.svc.cluster.local:9101
kubectl --context $CTX -n $NS rollout status deploy/noetl-worker-rust --timeout=5m
```

**(b) agent gate** — the five kind dimensions, re-proven under real load:

| dimension | check | pass |
| :-- | :-- | :-- |
| pool isolation (**hard req**) | worker log line `filter=commands.shared.>`; correlate claimed command ids against `execution_pool` | user pool claims **0** `system` commands, including `__orchestrate__` |
| exactly-once | distinct claimed `command_id` vs total claims across replicas | 0 duplicates |
| latency | append→claim p50/p99 vs Step 1 baseline | within the NATS envelope |
| redelivery | `ehdb_feed_total_lag` after a natural pod churn / rollout | lag resurges then drains, 0 lost commands, 0 stuck RUNNING |
| lag signal | `ehdb_feed_total_lag` vs real backlog | tracks and returns to ~0 (it now drains) |

Plus: shared-executions complete end-to-end; login/Muno path healthy;
no orphan-command sweeps firing; system pool still healthy on NATS.

**(c) pass** = all five green over a **24h** soak.
**Fail on any** — roll back immediately.

**(d) rollback**

```bash
kubectl --context $CTX -n $NS set env deploy/noetl-worker-rust NOETL_COMMAND_BUS=nats
kubectl --context $CTX -n $NS rollout restart deploy/noetl-worker-rust
kubectl --context $CTX -n $NS annotate scaledobject noetl-worker-rust \
  autoscaling.keda.sh/paused- --overwrite
```

The pool re-attaches its durable NATS consumer and drains the backlog it
accumulated during the canary; commands were never dual-consumed, so
there is nothing to reconcile.

### Step 4 — FULL FLIP (all pools + server on `ehdb`)

**(a) operator**

```bash
kubectl --context $CTX -n $NS annotate scaledobject \
  noetl-worker-system-pool-scaler-worker-system-pool \
  autoscaling.keda.sh/paused="true" --overwrite

kubectl --context $CTX -n $NS set env deploy/noetl-worker-system-pool \
  NOETL_COMMAND_BUS=ehdb NOETL_COMMAND_SHARD_COUNT=1 \
  NOETL_COMMAND_BUS_CLAIM_ADDR=noetl-cmdbus-writer.noetl.svc.cluster.local:9101

kubectl --context $CTX -n $NS set env deploy/noetl-cmdbus-writer NOETL_COMMAND_BUS=ehdb
kubectl --context $CTX -n $NS set env deploy/noetl-server-rust     NOETL_COMMAND_BUS=ehdb

kubectl --context $CTX -n $NS rollout status deploy/noetl-worker-system-pool --timeout=5m
kubectl --context $CTX -n $NS rollout status deploy/noetl-server-rust        --timeout=5m
```

Order matters: the system pool must be claiming from EHDB **before** the
server stops publishing to NATS, or system commands strand for the gap.

**(b) agent gate** — everything from Step 3 plus: the `__orchestrate__`
drive runs on the system pool over EHDB; the off-server state builder and
CQRS materializer keep up (materializer-lag alerts quiet); NATS consumer
pending flat at 0 (nothing new published); no orphan sweeps.

**(c) pass** = full-flip soak **72h** with NATS still installed.  Only
then: unpause the EHDB ScaledObject and retire the NATS ones.
**Do not proceed to T5 in the same window.**

**(d) rollback (any step, one block)**

```bash
kubectl --context $CTX -n $NS set env deploy/noetl-server-rust           NOETL_COMMAND_BUS=nats
kubectl --context $CTX -n $NS set env deploy/noetl-worker-rust           NOETL_COMMAND_BUS=nats
kubectl --context $CTX -n $NS set env deploy/noetl-worker-system-pool    NOETL_COMMAND_BUS=nats
kubectl --context $CTX -n $NS rollout restart deploy/noetl-server-rust \
  deploy/noetl-worker-rust deploy/noetl-worker-system-pool
kubectl --context $CTX -n $NS annotate scaledobject noetl-worker-rust \
  autoscaling.keda.sh/paused- --overwrite
kubectl --context $CTX -n $NS annotate scaledobject \
  noetl-worker-system-pool-scaler-worker-system-pool \
  autoscaling.keda.sh/paused- --overwrite
```

NATS was never deleted and commands are never dual-**consumed**, so this
is a clean revert: in-flight EHDB claims finish (bounded by `ack_wait`),
new commands publish to NATS again, no data reconciliation.

### T5 — delete NATS

**Out of scope for this document.**  Separate approval, after Step 4 has
baked.  Couples to [noetl/ai-meta#188](https://github.com/noetl/ai-meta/issues/188)
(retire the plaintext NATS credential).  Irreversible.

---

## Blockers before Step 0 can start

1. **ops PR** — writer Deployment + PVC + ClusterIP Service +
   VMServiceScrape (F3).
2. **F4 decision** — dedicated single-replica writer (preferred) vs
   pinning the system pool to `maxReplicaCount: 1`.
3. **Storage class + durability posture** for the writer PVC (open item
   on the wiki go/no-go checklist).
4. **PVC sizing** for the shadow window (F6).
5. **Live pre-flight output** (Part 1) to confirm F2 and the actual
   deployment/container names.
