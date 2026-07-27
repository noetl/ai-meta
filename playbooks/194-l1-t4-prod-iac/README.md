# L1 T4 command-bus cutover — shastaratech prod (executed 2026-07-27)

Reproducible IaC + executed-run record for the EHDB command-bus cutover on the
**new** shastaratech prod cluster. Companion to
[`../194-l1-t4-prod-cutover.md`](../194-l1-t4-prod-cutover.md) (the staged
runbook) and [noetl/ai-meta#194](https://github.com/noetl/ai-meta/issues/194).

```
CTX=gke_shastaratech-noetl-prod_us-central1_noetl-prod-autopilot
NS=noetl   (+ nats / nats-supercluster)
```

## What is DIFFERENT here vs the runbook (which was written for the old single-shard cluster)

| # | Delta | Consequence |
| :- | :- | :- |
| D1 | **2-shard cluster** — server `NOETL_COMMAND_SHARD_COUNT=2`, `NOETL_SHARD_SUBJECT_ROUTE=true`; system pool split into `noetl-worker-system-pool` (shard0) + `noetl-worker-system-pool-shard1` | Command bus needs **one writer PER shard** (server `PublishRouter` keeps one client per shard, errors on a missing shard; worker `spawn_writer_host` binds one `ClaimCoordinator` to `NOETL_COMMAND_BUS_SHARD`). ops#241 shipped ONE writer → adapted to TWO here. |
| D2 | **GMP, not VictoriaMetrics** — cluster runs Google Managed Prometheus (`gke-gmp-system`); no `VMServiceScrape` CRD | ops#241's `vmscrape-*` replaced with a GMP `PodMonitoring`. Live gates read the writer `:9102` directly via port-forward (stack-independent). |
| D3 | **Autopilot** — storageclass `premium-rwo` (PD-SSD) present; `standard-rwo` default (PD-balanced) | Writer PVC uses `premium-rwo` per the fsync-per-append posture. Autopilot defaults the init-container cpu (harmless warning). |
| D4 | **Images pulled from ghcr** — prod workers already pull `ghcr.io/noetl/worker`; server was on project AR `server-rust:v3.52.0` | server rolled to `ghcr.io/noetl/server@sha256:99b842…` (v3.58.0); no crane copy needed. |
| D5 | **worker v5.81.0** (task directive, newest, includes #199 sink) instead of the runbook's v5.78.0 | Superset of the subject-routed command bus. |

## Images deployed (digest-pinned)

- server **v3.58.0** = `ghcr.io/noetl/server@sha256:99b84214ce9f8430a612a814f5b924b8b3bbdaa38dcc8cbda14087639aeb0ba0`
- worker **v5.81.0** = `ghcr.io/noetl/worker@sha256:27807d74c2cc356883b057a814a9d4300323763b0f11fcd0eb34844f5a82fbe1`

## Files

| File | Role |
| :- | :- |
| `env.sh` | shared vars (context, images, writer DNS addrs) |
| `cmdbus-writer-shard0.yaml` | writer shard 0: PVC (premium-rwo 20Gi) + Deployment (singleton, Recreate) + ClusterIP Service |
| `cmdbus-writer-shard1.yaml` | writer shard 1 (identical bar shard index / names / consumer) |
| `cmdbus-writer-podmonitoring.yaml` | GMP PodMonitoring covering both writers (`:9102` lag + `:9090`) |
| `step0-rollforward.sh` | roll images forward + apply writer infra (bus stays NATS) |
| `step2-shadow.sh` | flip server + writers to `shadow` |
| `rollback.sh` | one-command bus→NATS on every deployment (any step) |
| `step0-undo.sh` | `rollout undo` the three roll-forward deployments |

## Executed run — 2026-07-27 (headless, synthetic load; user gave explicit GO)

Soak windows compressed to synthetic-load correctness gates (no organic traffic
window; the 24–72h calendar bakes in the runbook are not achievable in one
session).

### Step 0 — roll forward + writers (bus NATS) — **PASS**
- server → v3.58.0, all 3 worker deploys → v5.81.0; both writers up; PVCs Bound
  (premium-rwo, 20Gi); writers **inert** in nats mode (registered as workers on
  dead-end `noetl.commands.cmdbus.>`, `:9102` not bound).
- Synthetic gate: **15/15 hello_world COMPLETED over NATS**; 0 restarts.

### Step 1 — NATS baseline — **captured**
- command-path issued→claimed (n=90): **p50=338ms p95=511ms p99=520ms** (30/30 COMPLETED).
- This is the comparison envelope for later stages.

### Step 2 — SHADOW — **PASS (0 divergence)**
- server + both writers → `shadow`; workers stayed on NATS.
- Writer-host faces bound (ingest :9100 / claim :9101 / lag :9102 per shard).
- Server connected to writers **by DNS** (no IP literal, no `SocketAddr` error → finding #2 resolved).
- **Controlled parity (20 execs):** server published **121→NATS and 121→EHDB**;
  EHDB feed grew by exactly **121** (shard0 +61, shard1 +60); **EHDB shadow errors = 0**
  → **0 missed / 0 spurious**. Commands spread across **both** shards.
- Latency p50=273/p95=526/p99=579 ms — within the NATS envelope.
- Writer RSS/CPU **flat** (3m CPU / 4Mi mem, no climb); feed lag climbs
  monotonically (expected F6 — nothing claims in shadow); PVC 72K/19.5G; 0 restarts.
- No EHDB KEDA scaler exists in this cluster (nothing to pause).

### Step 3 — CANARY — **HELD (round 1). Blocker below → resolved by Option 2 (round 2).**

---

## Round 2 — 2026-07-27 — Option 2 (collapse command bus to 1 shard)

User chose **Option 2**. Kind-validated first, then reconfigured prod to 1 command shard, then re-ran the staged cutover.

- **Kind re-validation — PASS.** Mirrored prod-after-Option-2 (dedicated single writer + 2 state-shard system pools + `NOETL_COMMAND_SHARD_COUNT=1`). Single writer holds all commands (`ehdb_feed_total_lag→0`); user pool + both state-shard system pools compete **exactly-once (0 dup / 5 consumers)**; pod-kill redelivery 8/8 0-loss; rollback clean. **Axis independence** proven in code (command bus reads only `NOETL_COMMAND_SHARD_COUNT`; state materializer uses `NOETL_RESULT_SHARD_COUNT` + the event stream; `sharding.rs:172` "correctness never depends on affinity"). **Caught 3 config bugs, baked into the scripts:** system pools must share ONE NATS consumer (else JetStream double-delivers → dup exec); writer `NATS_STREAM` must match the cluster; **writer in `ehdb` mode requires `NOETL_COMMAND_BUS_CLAIM_ADDR` (self)**.
- **Prod reconfigure (`step1b-collapse-1shard.sh`, bus stayed NATS) — clean.** Unified system pools → shared consumer `noetl_worker_system_rust` on `noetl.commands.system.>`; server `NOETL_COMMAND_SHARD_COUNT=1` + single writer addr; writer-0 cmdshard=1 + self CLAIM_ADDR; writer-1 scaled to 0. **#166 state sharding INTACT** (both pools keep `NOETL_SHARD_COUNT=2`/index, `STATE_BUILDER=offserver`, `STATE_SHARD_WRITE=true`). 12/12 over NATS.
- **Shadow (`step2-shadow.sh`) — PASS, 0 divergence** (121 pub == 121 feed on the single writer, 0 errors, DNS connect).
- **Canary (`step3-canary.sh`, user pool → ehdb) — PASS** (15/15, **pool isolation 0 system claims**, 0 dup).
- **Full flip (`step4-fullflip.sh`) — FAILED.** All-ehdb steady-state (writer stable, feed lag=0): **~10% of executions stall permanently** — `command.issued` with no `command.claimed`. Server logged a successful EHDB publish + `ehdb_sort_key`; writer had no errors; lag=0 — the record is **ingested into the writer feed but never surfaced to a claimer**. Same load on NATS = 30/30 clean. Bug: **noetl/ai-meta#203** (ehdb-feed ClaimCoordinator/SubjectConsumerGroup ingest↔cursor race).
- **Rolled back (`rollback.sh`) — 30/30 clean, prod healthy.**

### Hold state after round 2

- Bus: **NATS** everywhere. Command bus config: **1 shard** (server cmdshard=1, single writer `noetl-cmdbus-writer-0` inert, writer-1 at 0 replicas, system pools on the shared consumer). Staged for a retry once #203 is fixed.
- #166 state/event sharding intact and healthy.
- ~6–9 orphaned synthetic `hello_world` execs stuck RUNNING (ehdb-loss casualties; harmless test data). Orphaned NATS consumers `noetl_worker_system_rust_shard0/shard1` hold ~40 stale msgs each (deletable).
- **T5 (delete NATS) never approached.**

### Round-1 blocker (kept for history)

## BLOCKER for canary + full flip — per-shard user-pool split (2-shard only)

On the EHDB bus every command is physically partitioned by `execution_id` across
shard 0 (writer-0) and shard 1 (writer-1) — **including the `shared` pool**
(proven in shadow: 61/60 split). On NATS today only the `system` pool is sharded
(`sharding.rs`: `ROUTABLE_POOL = "system"`); the `shared` subject is unsharded.

A worker claims from **exactly one** writer (`NOETL_COMMAND_BUS_CLAIM_ADDR` is a
single `host:port`; one `ClaimClient`). The **system pool is already split**
shard0/shard1, so each maps cleanly to its writer. The **user pool
(`noetl-worker-rust`) is a single deployment** — flipping it to `ehdb` with one
claim addr would strand ~half the `shared` commands (the ones on the other
shard). This split does not exist in ops#241 and was never integration-tested
(kind ran single-shard).

**Two ways forward (human design decision, then re-validate in kind before prod):**

1. **Split the user pool per shard** (mirrors the system pool): two deployments
   `noetl-worker-rust-shard0` (claim `writer-0:9101`) + `noetl-worker-rust-shard1`
   (claim `writer-1:9101`), each ~half the replicas, plus per-shard KEDA. Then
   canary one shard's user pool, then the other, then the system pool + server.
2. **Collapse the command bus to a single shard** — set `NOETL_COMMAND_SHARD_COUNT=1`
   for the *command bus axis* (distinct from the server's event/state sharding),
   so all commands land on writer-0 and the runbook's validated single-shard,
   single-writer, single-user-pool design applies unchanged. Changes system-pool
   command routing from partitioned to competing (still exactly-once). Simpler;
   diverges from the deployed #166 Phase 5 sharded command routing.

## Hold state left on prod (clean, reversible)

- Images: server **v3.58.0**, workers **v5.81.0** (validated).
- Writers: deployed, **inert** (`NOETL_COMMAND_BUS=nats`).
- Bus: **NATS** (shadow rolled back after the parity gate passed).
- Everything staged for canary once the per-shard user-pool decision lands.
- To re-enter shadow: `bash step2-shadow.sh`. To revert anything: `bash rollback.sh`.
- **T5 (delete NATS) NOT done** — out of scope, separate approval, couples to #188.
