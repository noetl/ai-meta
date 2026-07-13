# #166 Phase 5 — production rollout runbook (server-routed per-shard command publish + state-shard GC)

**Status:** prepared, NOT executed. These are commands for the
**user / prod-team** to run against GKE. The AI agent does not run
prod/GKE mutations. Prepared 2026-07-12 alongside the kind dry-run
(ops#238 harness + `scratchpad/dryrun-166-focused.sh`).

**What this rolls out:** [noetl/ai-meta#166](https://github.com/noetl/ai-meta/issues/166)
Phase 5, merged in **server v3.51.0** (Legs 1+2), flags default OFF.

- **Leg 1 — server-routed per-shard publish** (`NOETL_SHARD_SUBJECT_ROUTE`):
  the server publishes an execution's `system`-pool commands to
  `noetl.commands.system.shard.<n>.<eid>` (`n = shard_for(eid, NOETL_COMMAND_SHARD_COUNT)`)
  so the owning drive replica's per-shard consumer receives it first —
  removing the Phase-4 ~1-NAK-redirect-per-drive tax.
- **Leg 2 — state-shard GC** (`NOETL_RESULT_TIER_GC` + `NOETL_STATE_SHARD_GC`):
  the #104 result-tier GC sweep classifies + (opt-in) guards state
  shards; dry-run-first.

**Correctness invariant (load-bearing):** the sharded subject is a
**subtree** of the legacy pool wildcard `noetl.commands.system.>`, so
a broad-filter replica still receives a shard-routed command and
degrades to the Phase-4 NAK path — a wrong route never drops a hop.
`claim_command` atomicity is the single exactly-once gate regardless
of which consumer delivers. Everything here is **delivery steering**;
it never reorders/mutates/writes the event log.

---

## 0. Confirm the live prod topology BEFORE running anything (read-only)

Do not assume — confirm each value against the live cluster. The
committed ops manifest `worker-system-pool-deployment-prod.yaml` is
still the pre-shard single-replica spec; the live Phase-4 2-shard
topology was applied ad-hoc (ai-meta#166 Phase-4 prod note,
[[172-phase4-affinity-2deploy-prod]]), so the manifest is NOT the
source of truth for the live shard count.

```bash
CTX=<prod-gke-context>          # e.g. gke_noetl-demo-19700101_..._noetl-cluster
NS=noetl

# (a) server image must be >= v3.51.0 (has Phase 5 code)
kubectl --context $CTX -n $NS get deploy noetl-server-rust \
  -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'

# (b) the live system-pool shard topology. Phase 4 runs TWO single-replica
#     Deployments sharing one consumer, pinned NOETL_SHARD_INDEX 0 / 1,
#     NOETL_SHARD_COUNT=2. CONFIRM the replica/shard count — the
#     NOETL_COMMAND_SHARD_COUNT you set in Stage 1 MUST equal it.
kubectl --context $CTX -n $NS get deploy -l component=system-worker \
  -o custom-columns=NAME:.metadata.name,\
SHARD_INDEX:'.spec.template.spec.containers[0].env[?(@.name=="NOETL_SHARD_INDEX")].value',\
SHARD_COUNT:'.spec.template.spec.containers[0].env[?(@.name=="NOETL_SHARD_COUNT")].value',\
CONSUMER:'.spec.template.spec.containers[0].env[?(@.name=="NATS_CONSUMER")].value',\
FILTER:'.spec.template.spec.containers[0].env[?(@.name=="NATS_FILTER_SUBJECT")].value',\
STREAM:'.spec.template.spec.containers[0].env[?(@.name=="NATS_STREAM")].value'
#   → EXPECT (per Phase-4 prod): shard 0 = noetl-worker-system-pool,
#     shard 1 = noetl-worker-system-pool-shard1; NOETL_SHARD_COUNT=2 on both;
#     NATS_CONSUMER=noetl_worker_system_rust (shared); NATS_STREAM=NOETL_COMMANDS_RUST.
#   → SET SHARD_N=2 below to match this count. If the live count is not 2, use it.

# (c) the prod command stream (prod uses NOETL_COMMANDS_RUST, not kind's
#     NOETL_COMMANDS) must capture the shard subtree + use `limits` retention.
#     (Run from a jump box with the `nats` CLI + prod NATS creds.)
nats --server "$PROD_NATS_URL" stream info NOETL_COMMANDS_RUST --json \
  | python3 -c 'import sys,json;c=json.load(sys.stdin)["config"];print("subjects=",c["subjects"],"retention=",c["retention"])'
#   → EXPECT subjects include noetl.commands.> ; retention=limits.
#     `limits` (not workqueue) is REQUIRED so per-shard + broad consumers coexist.

# (d) cross-repo hash parity (server shard_for == worker shard_for). Use ops#238:
./repos/ops/automation/development/validate-shard-command-publish-166.sh
#   (point NS/KCTX/STREAM at a staging cluster, or run its Phase-0/1 against prod
#    read-only; the pinned vectors 325/8->4, 320816801799737344/16->14 must hold.)

SHARD_N=2      # <-- set to the confirmed live system-pool shard count from (b)
```

**Login note:** prod gateway runs `NOETL_AUTH_SYNC=true` (in-process
server auth fast-path, [[168-synchronous-auth-fastpath]]), so login does
**not** traverse the system-pool drive — none of these stages should
affect auth latency. Validate it anyway at each gate.

---

## Stage 1 — Mode A: server-routed publish ON (broad filters unchanged)

Server publishes to shard subjects; the fleet KEEPS the broad consumer,
so behaviour == Phase-4 (subsumption + NAK steering). This is
behaviour-neutral — the redirect tax is unchanged until Stage 2.

```bash
# APPLY (one server rolling restart)
kubectl --context $CTX -n $NS set env deploy/noetl-server-rust \
  NOETL_SHARD_SUBJECT_ROUTE=true NOETL_COMMAND_SHARD_COUNT=$SHARD_N
kubectl --context $CTX -n $NS rollout status deploy/noetl-server-rust --timeout=180s
```

**Validation gate (all must hold before Stage 2):**

```bash
# 1. server carries the flags
kubectl --context $CTX -n $NS get deploy noetl-server-rust \
  -o jsonpath='{range .spec.template.spec.containers[0].env[?(@.name=="NOETL_SHARD_SUBJECT_ROUTE")]}{.name}={.value}{"\n"}{end}'
# 2. real drive commands now publish to noetl.commands.system.shard.<n>.<eid>:
#    additive observer, no worker impact (delete after):
nats --server "$PROD_NATS_URL" consumer add NOETL_COMMANDS_RUST obs_shard0 \
  --pull --filter 'noetl.commands.system.shard.0.>' --deliver new --ack explicit --defaults
#    drive a real turn (Muno "Trip to Paris" or a system/ playbook), then:
nats --server "$PROD_NATS_URL" consumer next NOETL_COMMANDS_RUST obs_shard0 --count 20 --no-ack --timeout 3s
nats --server "$PROD_NATS_URL" consumer rm NOETL_COMMANDS_RUST obs_shard0 -f
# 3. metric noetl_command_publish_total{route="sharded",pool="system"} climbing
# 4. login fast (POST gateway /api/auth/validate {session_token:bogus} -> 200 {valid:false}, ~0.2-0.5s)
# 5. Muno "Trip to Paris" COMPLETES with correct widgets; 0 pod restarts on either shard replica
# 6. state_equivalence_mismatch_total == 0 on both shard replicas
```

**Rollback (behaviour-neutral either way, one restart):**

```bash
kubectl --context $CTX -n $NS set env deploy/noetl-server-rust \
  NOETL_SHARD_SUBJECT_ROUTE- NOETL_COMMAND_SHARD_COUNT-
kubectl --context $CTX -n $NS rollout status deploy/noetl-server-rust --timeout=180s
```

**Soak before Stage 2:** leave Stage 1 running long enough that any
pre-flip **legacy-subject** (`noetl.commands.system.<eid>`) commands
have drained. With Mode A on, *every new* `system`-pool command is
sharded — the only legacy commands are ones published before the flip.
Stage 2 removes the broad filter, so the legacy backlog MUST be empty
first (check the broad consumer's `Unprocessed`/`Ack Pending` → 0):

```bash
nats --server "$PROD_NATS_URL" consumer info NOETL_COMMANDS_RUST noetl_worker_system_rust \
  | grep -E 'Unprocessed|Ack Pending'   # both must be 0 before Stage 2
```

---

## Stage 2 — Mode B: per-shard consumers (removes the redirect tax)

Switch each system-pool shard replica from the shared broad consumer to
a **per-shard consumer** filtering only its shard subtree. This is what
drives the redirect tax to 0. **The gotcha:** the per-shard filter set
must cover **every** shard `[0, SHARD_N)` — because with Mode A on the
server shards *all* `system`-pool commands (drive AND `system/*` playbook
steps), a missing shard consumer strands that shard's commands. With the
2-Deployment topology (shard 0 + shard 1) and `SHARD_N=2`, shards 0 and 1
are both covered.

Roll **one replica at a time** so the not-yet-rolled replica keeps the
broad filter and catches everything (incl. the other shard, via
subsumption) during the transition.

```bash
# shard 0 replica -> its own per-shard consumer + filter
kubectl --context $CTX -n $NS set env deploy/noetl-worker-system-pool \
  NATS_CONSUMER=noetl_worker_system_rust_shard0 \
  NATS_FILTER_SUBJECT=noetl.commands.system.shard.0.>
kubectl --context $CTX -n $NS rollout status deploy/noetl-worker-system-pool --timeout=180s
#   (validate a Muno turn COMPLETES here — shard-1 replica still broad, so nothing strands)

# shard 1 replica -> its own per-shard consumer + filter
kubectl --context $CTX -n $NS set env deploy/noetl-worker-system-pool-shard1 \
  NATS_CONSUMER=noetl_worker_system_rust_shard1 \
  NATS_FILTER_SUBJECT=noetl.commands.system.shard.1.>
kubectl --context $CTX -n $NS rollout status deploy/noetl-worker-system-pool-shard1 --timeout=180s
```

The worker self-ensures its durable consumer on boot (no server change;
`NATS_CONSUMER` + `NATS_FILTER_SUBJECT` are env-driven). The old shared
consumer `noetl_worker_system_rust` becomes idle; delete it only after
confirming its `Unprocessed`/`Ack Pending` are 0:

```bash
nats --server "$PROD_NATS_URL" consumer info NOETL_COMMANDS_RUST noetl_worker_system_rust | grep -E 'Unprocessed|Ack Pending'
# when both 0:
nats --server "$PROD_NATS_URL" consumer rm NOETL_COMMANDS_RUST noetl_worker_system_rust -f
```

**Validation gate:**

```bash
# each shard replica bound to its own consumer/filter
kubectl --context $CTX -n $NS get deploy -l component=system-worker \
  -o custom-columns=NAME:.metadata.name,CONSUMER:'.spec.template.spec.containers[0].env[?(@.name=="NATS_CONSUMER")].value',FILTER:'.spec.template.spec.containers[0].env[?(@.name=="NATS_FILTER_SUBJECT")].value'
# redirect tax gone: noetl_worker_affinity_decisions_total{decision="redirected"} FLAT
#   (owner receives its shard directly; owned climbs, redirected/forced_local stop growing)
# object-store cold-load-from-shard stays ~0; mismatch_total==0; 0 restarts; login + Muno OK
```

**Rollback (ORDER MATTERS — restore broad filter BEFORE unsetting the
server flag, else a legacy command could strand):**

```bash
# 1. put both shard replicas back on the shared broad consumer/filter
kubectl --context $CTX -n $NS set env deploy/noetl-worker-system-pool \
  NATS_CONSUMER=noetl_worker_system_rust NATS_FILTER_SUBJECT=noetl.commands.system.>
kubectl --context $CTX -n $NS set env deploy/noetl-worker-system-pool-shard1 \
  NATS_CONSUMER=noetl_worker_system_rust NATS_FILTER_SUBJECT=noetl.commands.system.>
kubectl --context $CTX -n $NS rollout status deploy/noetl-worker-system-pool --timeout=180s
kubectl --context $CTX -n $NS rollout status deploy/noetl-worker-system-pool-shard1 --timeout=180s
# 2. THEN (optionally) unset the server flag (Stage 1 rollback)
kubectl --context $CTX -n $NS set env deploy/noetl-server-rust NOETL_SHARD_SUBJECT_ROUTE- NOETL_COMMAND_SHARD_COUNT-
```

---

## Stage 3 — Leg 2: state-shard GC, dry-run first

Enable the GC sweep in **dry-run** (the endpoint defaults to
`dry_run=true`; the env flag just lets the sweep actually scan). Read
per-class counts across a soak BEFORE ever enabling delete-mode.

```bash
# APPLY (one server restart) — can be folded into Stage 1's server restart
kubectl --context $CTX -n $NS set env deploy/noetl-server-rust \
  NOETL_RESULT_TIER_GC=1 NOETL_STATE_SHARD_GC=true
kubectl --context $CTX -n $NS rollout status deploy/noetl-server-rust --timeout=180s

# DRY-RUN sweep (internal endpoint; needs the internal API token bearer)
TOKEN=$(kubectl --context $CTX -n $NS get secret noetl-internal-api-token -o jsonpath='{.data.token}' | base64 -d)
kubectl --context $CTX -n $NS port-forward svc/noetl-server-rust 8082:8082 &   # or curl in-cluster
curl -s -X POST http://127.0.0.1:8082/api/internal/result-tier/gc \
  -H "authorization: Bearer $TOKEN" -H 'content-type: application/json' \
  -d '{"dry_run":true,"limit":1000}' | python3 -m json.tool
#   → REVIEW: enabled=true, dry_run=true, deleted=0 (ALWAYS 0 in dry-run),
#     scanned, state_shard_candidates, state_open_guard_protected, skipped_live,
#     errors=0. state_shard_guard=true means OPEN shards get the extended grace.
#   Repeat the dry-run across a soak (or a cron). Enabling delete-mode
#   ({dry_run:false}) is a SEPARATE, later gated decision — not this stage.
```

**Rollback (one restart):**

```bash
kubectl --context $CTX -n $NS set env deploy/noetl-server-rust \
  NOETL_RESULT_TIER_GC- NOETL_STATE_SHARD_GC-
```

---

## Post-rollout

- Update the ops committed manifests to capture the shard topology as
  declarative YAML (the live Phase-4/5 topology is currently ad-hoc) —
  separate ops PR.
- Comment on [noetl/ai-meta#166](https://github.com/noetl/ai-meta/issues/166)
  with the rollout evidence; the umbrella stays OPEN until the rollout
  lands and (optionally) delete-mode GC is enabled. Leg 3 (P2P
  warm-handoff) remains deferred.

## Kind dry-run evidence (2026-07-12 — proves the sequence works + reverses)

Ran the full sequence against `kind-noetl` (podman), context-guarded,
with a trap restoring baseline on any failure. Server image
`ehdb178-merged` (has Phase 5 code); the single kind system-pool worker
kept its broad consumer throughout (Mode A validated via subsumption).

**Baseline → Mode A → GC dry-run → rollback, all green:**

| Stage | Evidence |
|---|---|
| Baseline | drive `hello_world` → command on **legacy** `noetl.commands.system.<eid>` (no `.shard.`); server has no Phase-5 flags. |
| Mode A ON | `set env NOETL_SHARD_SUBJECT_ROUTE=true NOETL_COMMAND_SHARD_COUNT=2` (+ GC flags) → 1 rolling restart. 3 drives routed by `shard_for(eid,2)`: eid…5504→shard **0**, …2720→shard **1**, …4928→shard **1**, each on `noetl.commands.system.shard.<n>.<eid>`. Observed on additive consumers: **shard-0=3, shard-1=7, broad=10** (broad subsumes both shards). A drive **COMPLETED** under Mode A — the existing broad-filter worker still drains sharded commands via subsumption (Mode A is behaviour-neutral, as designed). |
| Leg-2 GC dry-run | `POST /api/internal/result-tier/gc {dry_run:true}` (auth bearer) → HTTP 200: `enabled=true dry_run=true scanned=1000 deleted=0 skipped_live=1000 state_shard_candidates=0 state_open_guard_protected=0 state_shard_guard=true errors=0`. **deleted=0** (dry-run safe); `skipped_live=1000` = the SkipLive invariant protecting in-flight objects; no aged sealed state shards to reclaim in this window. |
| Rollback | `set env …SUBJECT_ROUTE- …COMMAND_SHARD_COUNT- …RESULT_TIER_GC- …STATE_SHARD_GC-` → 1 restart. All Phase-5 flags unset; post-rollback drive back to **legacy** `noetl.commands.system.<eid>` — baseline fully restored, reversible. |

Cluster left exactly as found: server 0 Phase-5 flags / 0 restarts,
additive observation consumers trap-deleted, real worker consumers +
in-flight EHDB work undisturbed. No GKE/prod touched; `noetl.event`
never purged; no secrets printed.

**Correction to the ops#238 harness caveat (verified here):** with
Mode A on, the server shard-routes **every** `pool==system` command
(the drive command AND `system/*` playbook steps), not only the drive —
so there is no separate "legacy" subject for non-drive system commands
once the flag is on. The genuine requirement is therefore: **per-shard
consumers must cover all shards `[0, NOETL_COMMAND_SHARD_COUNT)`**, and
the broad consumer is retained only through the transition to drain any
pre-flip legacy commands (Stage 1 soak), then retired (Stage 2). The
Stage-2 rollback restores the broad filter *before* unsetting the server
flag for exactly this reason.
