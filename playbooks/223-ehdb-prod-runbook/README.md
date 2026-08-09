# EHDB prod runbook — the three gcloud-blocked workstreams, in one sequence

**Status: P0 DONE (read-only). P1–P5 not run.**

- **P0 executed 2026-08-03** against `shastaratech-noetl-prod`, read-only.
  Results and the corrections they force: [`P0-discovery.md`](P0-discovery.md).
- **P3/P4 hardened 2026-08-03** on the back of P0 — six IaC defaults that would
  have broken or misconfigured prod are fixed in ops#245 @ `5e28543` and
  validated against local kind (plan / converge / idempotent no-op). Prod was
  **not** converged and nothing here has been applied to it.
- Everything else below is still planning only.

Three pieces of EHDB work are finished, kind-validated, and waiting on the same
thing — a gcloud re-auth against `shastaratech-noetl-prod`:

| # | Workstream | Where it lives | State |
| :- | :-- | :-- | :-- |
| 1 | Three silent-failure fixes in the worker | [noetl/worker#211](https://github.com/noetl/worker/pull/211) → [ai-meta#221](https://github.com/noetl/ai-meta/issues/221), [ai-meta#209](https://github.com/noetl/ai-meta/issues/209), [ehdb#311](https://github.com/noetl/ehdb/issues/311) | PR open, `cargo test` 575/0, **not released** |
| 2 | The EHDB-only topology as IaC | [noetl/ops#245](https://github.com/noetl/ops/pull/245) → [ai-meta#222](https://github.com/noetl/ai-meta/issues/222) | PR open, kind-validated, **never run against prod** |
| 3 | The prod soak | [ehdb#261](https://github.com/noetl/ehdb/issues/261) Phase 2 | kind soak PASS; the numbers that matter **cannot be produced in kind** |

This document stitches them into one ordered sequence with gates, verification
and rollback per phase.

> **There is no command-bus fallback.** NATS was deleted from prod on
> 2026-08-01 ([ai-meta#212](https://github.com/noetl/ai-meta/issues/212));
> namespaces `nats` and `nats-supercluster` are gone and the NATS code paths
> were removed from server, gateway and the worker's command path
> (server v3.60.2 / worker v5.91.2 / gateway v3.7.1, `GET /api/health` →
> `"nats":"removed"`). Every rollback in this document is an **image or
> topology rollback**. `NOETL_COMMAND_BUS=nats` is not a thing you can flip
> back to any more, and `playbooks/194-l1-t4-prod-iac/rollback.sh` is dead —
> it rolls back to a broker that does not exist.

---

## Executive checklist — one screen

```
P0  RE-AUTH + READ-ONLY DISCOVERY                              [safe, reversible]
    gcloud auth login --account=shastaratech@gmail.com
    Record: context · image digests · writer workload+PVC names ·
            bus=ehdb · the 4 fail-loud env vars · KEDA state · grace period
    GATE: every row of the discovery table filled in. No blanks, no guesses.

P1  RELEASE + ROLL worker#211                                  [reversible: prior digest]
    P1a  merge PR with a conventional subject; semantic-release versions + tags
    P1b  GHCR -> AR by digest with `crane` (publish-ar is broken, ai-meta#211)
    P1c  ENV PRECONDITION CHECK — the fail-loud vars, or the roll crashloops
    P1d  roll: writer(s) first, then server, then the pools    << writer pod drops
    GATE: 0 CrashLoopBackOff · 20/20 executions · published==projected==cursors
    ROLLBACK: kubectl set image back to the recorded prior digests

P2  PROD SOAK (ehdb#261 Phase 2)                               [P2a-c safe; P2d DESTRUCTIVE]
    P2a  in-cluster metrics sampler (survives the writer dying)
    P2b  throughput + dispatch latency at prod concurrency
    P2c  the unsealed-window bound, measured WITHOUT destroying anything  <- default
    P2d  OPTIONAL hard SIGKILL measurement   *** HUMAN GO-AHEAD REQUIRED ***
         can permanently lose durable noetl.event records. Read P2d before running it.
    P2e  KV + SSE under the gateway's real traffic; cursor_errors at prod rates
    GATE: 0 dup / 0 loss / 0 out_of_order · lag returns to 0 · cursor_errors 0

P3  IaC PLAN (ops#245 @ 5e28543+, profile=prod)                [safe, changes nothing]
    action=plan, then READ THE DIFF. Six values that used to be `--set`
    overrides are now prod-matching DEFAULTS — invisible on the command
    line, so the plan diff is the only place they get checked (see P3).
    GATE: the plan matches the discovery table — PVC names, state_builder=
          offserver, ns gateway, writer 4Gi, both system pools, and the
          Service-selector REPLACE line.

P4  IaC CONVERGE — Deployment -> StatefulSet                   [*** IRREVERSIBLE-ISH ***]
    P4a  save the live writer Deployment YAML   <- the only rollback artefact
    P4b  converge writer + runtime, autoscaler DEFERRED         << writer pod drops
    P4c  converge the autoscaler separately (already converged per P0 — an
         idempotence check, not a live change; the #210 signature is absent)
    GATE: durable log survived (tip continuity) · Service HAS endpoints ·
          verify PASS on all three groups · gen unchanged on re-run
    ROLLBACK: scale sts to 0, re-apply the saved Deployment, PVCs are untouched

P5  POST-CONVERGE RE-VERIFY + WATCH
    Re-run the P2b latency measurement on the new topology; watch the
    autoscaler for one scale-up/scale-down cycle.
```

**Irreversible or safety-line-crossing steps: P1d, P2d, P4b, P4c.** Full list
with reasons in [Irreversible steps](#irreversible-steps) at the bottom.

---

## Phase ordering, and why

**Order: P0 discovery → P1 release/roll → P2 soak → P3 plan → P4 converge → P5 watch.**

This is the order proposed in the task, and the dependencies confirm it rather
than force a change. The reasoning, because "risk order" alone is not enough:

**P1 must precede P4 — a hard dependency, not a preference.** The IaC's
Deployment→StatefulSet handover deliberately drops the writer pod once. What
makes that survivable rather than lossy is exactly the fix in worker#211: the
sequenced `stop ingest → quiesce → persist cursor → seal and hold` shutdown.
Before #211 the seal raced process exit and *usually did not run at all*, and
the **events** writer never sealed under any circumstance — and that feed is
the sole writer of the durable `noetl.event` log, because the server runs
`NOETL_EVENT_INGEST_PUBLISH_ONLY=true` and writes zero rows itself. Converging
the IaC on the current image means taking a deliberate writer-pod drop with the
unsealed-tail bug still in place. Do not do that.

**P2 must precede P4, for measurement reasons.** Two of them:

- The soak's headline number — the unsealed-tail exposure — is only meaningful
  at a *known, stable* consumption lag. P4c unpauses the user-pool autoscaler
  (2 → up to 20 replicas), which changes consumption rate and therefore the lag
  regime. Measure on the current fixed 8-slot pool, where the number means one
  thing.
- If the soak fails, the diagnosis is "the new image", full stop. Converge the
  topology first and a failure is ambiguous between image and topology, on a
  platform with no bus fallback and a novel workload shape. Keep exactly one
  variable moving at a time.

**Does worker#211's fail-loud env have to land via the IaC first?** No — and
this was the one thing that could have forced a re-order, so it is worth
stating precisely. The strict resolver only demands a source variable when the
matching consumer is **already enabled**:

| Var | Demanded only when |
| :-- | :-- |
| `NOETL_MATERIALIZER_SOURCE` | `NOETL_MATERIALIZER_ENABLED` truthy |
| `NOETL_RESULT_MATERIALIZER_SOURCE` | `NOETL_RESULT_MATERIALIZER_ENABLED` **or** `NOETL_RESULT_MINT_AUTHORITATIVE` **or** `NOETL_RESULT_TIER_DR` truthy |
| `NOETL_STATE_MATERIALIZER_SOURCE` | `NOETL_STATE_SHARD_WRITE` truthy — **not** a `..._MATERIALIZER_ENABLED` var |
| `NOETL_STATE_BUILDER_SOURCE` | `NOETL_STATE_BUILDER=offserver` **or** `NOETL_STATE_BUILDER_SHADOW` truthy |

Prod already migrated its live materializers to `ehdb` during the cutover, so
those variables should already be set. "Should" is not evidence, so this is a
**read-only precondition check in P0 and again in P1c**, not a reordering. If a
variable turns out to be missing, the fix is one targeted `kubectl set env` on
the old image *before* the roll — cheaper, smaller and more reversible than
pulling the whole IaC converge forward.

**Why the autoscaler is split out of the converge (P4c).** The ScaledObject is
a different blast radius from the bus topology: it changes replica counts, not
data paths, and its failure mode ([ai-meta#210](https://github.com/noetl/ai-meta/issues/210)) is
scaling misbehaviour rather than loss. Converging both at once means a scaling
anomaly and a topology anomaly are indistinguishable. Run the writer+runtime
converge with `--set autoscaler_enabled=false`, verify, then converge the
autoscaler on its own.

---

## P0 — gcloud re-auth and read-only prod discovery

**Nothing downstream may run on an assumption this phase did not confirm.** The
IaC's `claim_*` PVC names in particular came from the *soak reconstruction*,
not from prod.

### Preconditions

- `gcloud`, `kubectl`, `crane`, `gh`, `jq` on PATH.
- The account matters: administering `shastaratech-noetl-prod` requires
  `--account=shastaratech@gmail.com`. Two prior sessions lost time to a wrong
  active account presenting as a permissions problem
  ([ai-meta#204](https://github.com/noetl/ai-meta/issues/204)).

### Commands

```bash
gcloud auth login --account=shastaratech@gmail.com
gcloud config set account shastaratech@gmail.com
gcloud config set project shastaratech-noetl-prod
gcloud container clusters get-credentials noetl-prod-autopilot \
  --region us-central1 --project shastaratech-noetl-prod

export CTX=gke_shastaratech-noetl-prod_us-central1_noetl-prod-autopilot
export NS=noetl
K() { kubectl --context "$CTX" -n "$NS" "$@"; }

kubectl config current-context     # must print $CTX exactly
```

Then fill in every row of this table. Leave nothing blank.

```bash
# 1. workloads
K get deploy,sts,pods -o wide

# 2. running image digests (the rollback targets)
K get deploy,sts -o \
  jsonpath='{range .items[*]}{.kind}/{.metadata.name}{"\t"}{range .spec.template.spec.containers[*]}{.name}={.image}{"\n"}{end}{end}'

# 3. THE WRITER: workload kind, name, strategy, PVC names, grace period
K get deploy -l app=noetl-cmdbus-writer -o yaml | \
  grep -E 'name:|strategy:|type:|claimName:|terminationGracePeriodSeconds:'
K get pvc
K get pvc -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.storageClassName}{"\t"}{.spec.resources.requests.storage}{"\n"}{end}'

# 4. the bus is EHDB, and NATS is really gone
K get deploy noetl-server-rust -o jsonpath='{.spec.template.spec.containers[?(@.name=="noetl-server")].env}' | jq '.[]|select(.name|test("BUS|NATS|EVENT_INGEST"))'
kubectl --context "$CTX" get ns | grep -i nats || echo "no nats namespaces — expected"
K exec deploy/noetl-server-rust -c noetl-server -- \
  sh -c 'command -v curl >/dev/null && curl -s localhost:8082/api/health' | jq .nats

# 5. THE FAIL-LOUD PRECONDITION MATRIX  (P1 crashloops without this)
for d in noetl-worker-rust noetl-worker-system-pool noetl-worker-system-pool-shard1; do
  echo "=== $d ==="
  K get deploy "$d" -o json 2>/dev/null | jq -r '
    .spec.template.spec.containers[].env // [] | map(select(.name|test(
      "MATERIALIZER_ENABLED|MATERIALIZER_SOURCE|STATE_SHARD_WRITE|STATE_BUILDER|RESULT_MINT_AUTHORITATIVE|RESULT_TIER_DR|FEED_FILTER_SUBJECT|COMMAND_BUS|EVENT_BUS"
    ))) | .[] | "\(.name)=\(.value)"'
done

# 6. KEDA
K get scaledobject -o yaml | grep -E 'name:|paused|minReplicaCount|maxReplicaCount|type:|serverAddress|valueLocation|metricName'
K get hpa                       # a PAUSED ScaledObject means NO HPA HERE AT ALL
K get deploy noetl-worker-rust -o jsonpath='{.spec.replicas}{"\n"}'

# 7. monitoring CRDs (which scrape object the IaC will render)
kubectl --context "$CTX" get crd | grep -Ei 'podmonitoring|vmpodscrape'
```

### Discovery table — fill this in before proceeding

| Fact | Expected (from the record) | Observed |
| :-- | :-- | :-- |
| Context | `gke_shastaratech-noetl-prod_us-central1_noetl-prod-autopilot` | |
| server image + digest | v3.60.2 | |
| worker image + digest | v5.91.2 | |
| gateway image + digest | v3.7.1 | |
| Writer workload kind + name | Deployment `noetl-cmdbus-writer-0` | |
| Writer `strategy.type` | must be `Recreate` (RWO) | |
| Writer `terminationGracePeriodSeconds` | ≥ 30 | |
| Writer PVC names | IaC assumes `noetl-cmdbus-writer-data`, `noetl-eventbus-writer-data`, `noetl-eventbus-kv-data` | |
| PVC storage class | `premium-rwo` | |
| `NOETL_COMMAND_BUS` / `NOETL_EVENT_BUS` | `ehdb` / `ehdb` | |
| `NOETL_EVENT_INGEST_PUBLISH_ONLY` | `true` (⇒ materializer is the sole `noetl.event` writer) | |
| `NOETL_MATERIALIZER_ENABLED` / `_SOURCE` | true / `ehdb` | |
| `NOETL_RESULT_MATERIALIZER_ENABLED` / `_SOURCE` | true / `ehdb` | |
| `NOETL_STATE_SHARD_WRITE` | expected **false/unset** on prod (#217) | |
| `NOETL_STATE_MATERIALIZER_SOURCE` | may be unset — fine *iff* the row above is false | |
| `NOETL_STATE_BUILDER` / `_SHADOW` / `_SOURCE` | `server` / unset / may be unset | |
| `NOETL_FEED_FILTER_SUBJECT` per pool | `noetl.commands.shared.>` / `noetl.commands.system.>` | |
| ScaledObject name / paused / trigger | uncertain — was paused with a nats trigger | |
| HPA present? | **no**, if the SO is paused | |
| Monitoring CRD | `PodMonitoring` (GMP) | |
| Shard count | 1 | |

### Gate

Proceed only when: the context is exactly right, the writer's PVC names are
**recorded verbatim**, and the fail-loud matrix has no enabled-consumer-without-a-source row.

If a PVC name differs from the IaC defaults → see [P3, the un-threaded
parameters](#p3--iac-plan). If a fail-loud row is missing → fix it in P1c
before the roll.

### Rollback

None needed. This phase is read-only.

---

## P1 — release and roll worker#211

Ships three fixes, all closing **silent** failures:

1. **Fail-loud internal bus source** ([ai-meta#221](https://github.com/noetl/ai-meta/issues/221)) —
   unset / blank / typo'd (`ehbd`) no longer resolves to the deleted NATS
   transport. Resolved on the startup path for all four consumers, so a bad
   value is a crashloop instead of a dead materializer with a flat cursor.
   `Default` impl dropped; `NATS_URL` no longer defaults to
   `nats://localhost:4222`.
2. **Sequenced, awaited writer seal on SIGTERM** ([ai-meta#209](https://github.com/noetl/ai-meta/issues/209),
   graceful half) — `stop ingest → quiesce → persist cursor → seal and hold`,
   under a bounded budget. `seal_and_hold` deliberately leaks the engine mutex
   guard so a post-seal publisher blocks and is **never acked**; the server's
   republish (server#290) then sends it to the replacement writer.
3. **Face supervision** — every bus face's accept loop is now supervised and
   logs at ERROR when it ends. Worker-side mitigation for
   [ehdb#311](https://github.com/noetl/ehdb/issues/311) (one connection that
   sends nothing and closes permanently kills an events face, silently). Note
   the branch pins ehdb `ddb7ac9`, which does **not** contain an ehdb-side fix
   for #311 — this is mitigation, not cure.

### P1a — merge, and let semantic-release version it

> **Corrected 2026-08-04 (noetl/ai-meta#224).** This step used to say "bump
> `Cargo.toml` manually, then tag". Doing that is what caused the version
> regression on 2026-08-03: the manual bump to 5.92.0 merged at 22:28:24, and
> 24 seconds later semantic-release — which knows nothing about manual bumps —
> computed a patch bump from 5.91.2, pushed `Cargo.toml = 5.91.3` and tagged
> v5.91.3. `main` then claimed a version *lower* than the newest published tag,
> and every subsequent automatic release inherited it.
>
> **semantic-release owns versioning in this repo. Never hand-edit
> `Cargo.toml`** — it gets rewritten on the next push to `main` regardless.

The release is driven entirely by the merge commit's message:

```bash
cd repos/worker
cargo test && cargo clippy --all-targets
```

> ⚠ Do **not** run bare `cargo fmt --all` in this repo — rustfmt 1.9.0 reflows
> unrelated files across the ehdb-adjacent crates. Format only what you edited.

Merge with a **merge commit** (this repo forbids squash) and a conventional
subject, because that subject is what semantic-release reads to pick the bump —
`fix:` → patch, `feat:` → minor, `!`/`BREAKING CHANGE:` → major:

```bash
gh pr merge 211 --repo noetl/worker --merge
```

Then **wait for semantic-release to do the rest.** It bumps `Cargo.toml`,
commits, tags, and dispatches `release.yml` — whose `verify-version` job then
passes by construction, because the commit it tagged is the one carrying the
matching version. Do not push a tag by hand; a hand-pushed tag races the bot and
recreates the regression.

```bash
gh run watch --repo noetl/worker            # semantic-release, then release.yml
git fetch origin --tags
git tag --sort=-v:refname | head -1         # the version it actually chose
```

Take the resulting tag as the version for P1b — do not assume it in advance.

**Expect `publish-ar` to fail red.** That is
[ai-meta#211](https://github.com/noetl/ai-meta/issues/211): the build SA cannot
stage source in `gs://shastaratech-noetl-prod_cloudbuild`
(`ERROR: (gcloud.builds.submit) The user is forbidden from accessing the bucket
[shastaratech-noetl-prod_cloudbuild]`). It is decoupled from `github-release`,
so it cannot block the release. `publish-image` + `publish-manifest` (GHCR,
multi-arch) are the artefacts of record.

**Gate:** `publish-manifest` green; `ghcr.io/noetl/worker:5.92.0` is a
two-arch manifest list.

### P1b — GHCR → Artifact Registry by digest, via crane (FALLBACK)

> **As of 2026-08-09 this step is no longer required.** `publish-ar` publishes
> to Artifact Registry on every release — fixed in
> [noetl/server#339](https://github.com/noetl/server/pull/339) by passing
> `--gcs-source-staging-dir` so `gcloud builds submit` skips the bucket-discovery
> call that needed project-level `storage.buckets.list`. Verified green on runs
> `31337162229` and `31337178005`, with `v3.79.4` present in AR.
>
> **Keep this step as the escape hatch.** If `publish-ar` ever regresses, the
> `crane` copy below still works and is the fastest way to unblock a deploy.
> Check the job before reaching for it: `gh run list --repo noetl/<repo>`.


```bash
crane copy ghcr.io/noetl/worker:5.92.0 \
  us-central1-docker.pkg.dev/shastaratech-noetl-prod/noetl/noetl-worker-rust:5.92.0

WORKER_IMG=$(crane digest --full-ref \
  us-central1-docker.pkg.dev/shastaratech-noetl-prod/noetl/noetl-worker-rust:5.92.0)
echo "$WORKER_IMG"   # record it — this is what gets deployed and what P4 pins
```

Deploy **by digest**, never by tag. The IaC's `writer_image` in P3/P4 is this
same digest.

**Gate:** `crane manifest` on the AR ref resolves and its `linux/amd64` digest
matches GHCR's.

### P1c — env precondition check (the crashloop guard)

The fail-loud change turns a previously-tolerated misconfiguration into a
startup failure. Re-read the P0 matrix and satisfy this rule on **every**
worker workload that will receive the new image:

> For each of the four consumers: if its enable-flag is truthy, its `_SOURCE`
> variable **must** be present and spelled exactly `ehdb` (or `nats`, which
> would be an explicit and wrong choice now).

Two traps worth naming, because both have already produced silent failures:

- The state materializer's enable flag is **`NOETL_STATE_SHARD_WRITE`**, not
  `NOETL_STATE_MATERIALIZER_ENABLED`.
- The result materializer's source becomes required via **three** independent
  flags — `NOETL_RESULT_MATERIALIZER_ENABLED`, `NOETL_RESULT_MINT_AUTHORITATIVE`
  and `NOETL_RESULT_TIER_DR`. Checking only the first is not enough.

Fix any gap on the *old* image first, and confirm it rolls clean:

```bash
K set env deploy/noetl-worker-system-pool NOETL_RESULT_MATERIALIZER_SOURCE=ehdb
K rollout status deploy/noetl-worker-system-pool --timeout=300s
```

New optional knobs #211 introduces (defaults are fine; listed so a crashloop is
not misdiagnosed):

| Var | Default | Meaning |
| :-- | :-- | :-- |
| `NOETL_EHDB_SHUTDOWN_TIMEOUT_MS` | `15000` | Total seal budget. Must stay **below** the pod's `terminationGracePeriodSeconds` — otherwise a graceful stop becomes the SIGKILL that loses data. |
| `NOETL_EHDB_SHUTDOWN_QUIESCE_MS` | `250` | Window for already-accepted ingest connections to finish. |

Cross-check against the P0 grace-period reading: with the 15 s default, the
writer needs `terminationGracePeriodSeconds` ≥ ~30 (the IaC StatefulSet in P4
sets 60).

**Gate:** every enabled consumer has a source; grace period > shutdown budget.

### P1d — roll — ⚠ the writer pod drops

**Deploy order: writer(s) → server → pools.** Claimers come up last, against an
already-running writer. This is the order used successfully in
`playbooks/205-208-prod-rollout/`.

> ⚠ **`--type strategic` (the default), never `--type merge`, when patching the
> writer.** A JSON-merge patch replaces the `containers` array wholesale and
> wipes the writer's env, ports, volumeMount and probes. That happened during
> the #205/#208 rollout; recovery was `kubectl rollout undo`.

```bash
# 1. writer first — THIS DROPS THE BUS FOR THE POD-RESTART WINDOW
K set image deploy/noetl-cmdbus-writer-0 noetl-worker="$WORKER_IMG"
K rollout status deploy/noetl-cmdbus-writer-0 --timeout=600s
K logs deploy/noetl-cmdbus-writer-0 --tail=50 | grep -Ei 'seal|shutdown|face|ERROR'

# 2. server
K set image deploy/noetl-server-rust noetl-server="$SERVER_IMG_UNCHANGED"   # no-op unless server also moves
K rollout status deploy/noetl-server-rust --timeout=600s

# 3. pools last
for d in noetl-worker-rust noetl-worker-system-pool noetl-worker-system-pool-shard1; do
  K set image deploy/$d --all="false" "$(K get deploy $d -o jsonpath='{.spec.template.spec.containers[0].name}')=$WORKER_IMG"
  K rollout status deploy/$d --timeout=600s
done
```

> ⚠ Target containers **by name**, never `*`. The system pool's `wait-for-api`
> init container is `curlimages/curl`; a wildcard swaps it for the worker image,
> which has no `curl`, and the init loop spins forever. This is defect #1 from
> the EHDB-only cutover.

**Writer-drop expectations.** Commands issued during the window are re-issued
by the orphaned-command guardrail
([ai-meta#171](https://github.com/noetl/ai-meta/issues/171)) roughly 30 s later.
Expect possible `HTTP 500` on `POST /api/execute` during the writer's absence —
fail-closed, the caller is told, no silent loss (observed twice during the
#205/#208 roll). Redial was measured at ~2.7 s once the writer is back.

### Verification and gate

```bash
K get pods -w    # 0 CrashLoopBackOff, 0 restarts after settle

# paired evidence, not an execution count
# baseline
K exec deploy/noetl-server-rust -c noetl-server -- sh -c 'curl -s localhost:8082/metrics' \
  | grep -E 'noetl_ehdb_events_published_total|noetl_events_projected_total|publish_errors'
# fire 20 executions, then re-read and diff
```

| Gate | Pass |
| :-- | :-- |
| Pods | 0 CrashLoopBackOff, 0 restarts after settle |
| Executions | 20/20 COMPLETED |
| `published == projected` | exact equality of the deltas |
| Every **enabled** materializer group cursor | advanced by that same delta, ending lag 0 |
| `ehdb_events_cursor_errors` | 0 |
| `ehdb_l0_out_of_order_appends` | 0 |
| Duplicate execution ids | 0 |
| Face liveness | all nine ports listening, read from `netstat -ltn` **inside the pod** |

> ⚠ **Never connect to :9104, :9107 or :9108 to check them.** Those faces speak
> the ehdb-feed wire protocol and `ehdb_feed::serve` handshakes *inside* its
> accept loop — a connect that sends nothing and closes is enough to drop the
> listener permanently, with one ERROR line and nothing else (ehdb#311). `nc -z`
> does it. A Kubernetes `tcpSocket` probe does it on every period, forever.
> Read liveness from the pod's own listening sockets. :9102 and :9106 are HTTP
> `/metrics` and are safe to curl.

An **unreadable metric is a FAILURE, never a zero.** A poll that coerces `NA`
to 0 "drains" instantly and passes; that false pass has already been produced
once against this topology.

### Rollback

```bash
PREV_WORKER=<digest recorded in P0>
K set image deploy/noetl-cmdbus-writer-0 noetl-worker="$PREV_WORKER"
for d in noetl-worker-rust noetl-worker-system-pool noetl-worker-system-pool-shard1; do
  K set image deploy/$d <container-name>="$PREV_WORKER"; done
```

Rolling back reinstates the unsealed-tail exposure and the silent-source
default. It does **not** change the bus — there is nothing to change it to.

---

## P2 — the prod soak (ehdb#261 Phase 2)

The kind soak
([`playbooks/220-ehdb-only-kind-soak/`](../220-ehdb-only-kind-soak/)) passed
every paired-evidence gate — 360 executions, `published == projected == 6840`,
all three group cursors at lag 0, `cursor_errors` 0, 3 SSE subscribers at
identical 7864 frames, 880 KV ops with 0 mismatches. It proved **correctness
under concurrency** and **graceful-shutdown behaviour**.

It explicitly could not produce four numbers, and those four are this phase:

1. **Bus throughput and dispatch latency at prod concurrency.** In kind the bus
   was never the bottleneck — shard lag sat at 0 through every round while the
   pool (2 × `WORKER_MAX_CONCURRENT=4` = 8 slots) saturated. A saturating burst
   in kind measures the pool, not EHDB. Same reason
   [ai-meta#205](https://github.com/noetl/ai-meta/issues/205) could not be
   reproduced there.
2. **The hard-kill unsealed-tail loss**, which is *masked* in kind: under that
   backlog the committed cursor trailed the tip by ~1100 records — more than
   `seal_max_records` (1024, the ceiling; observed cadence is 20-140 records)
   — so anything lost from an unsealed part had not
   been consumed yet and was simply redelivered. The corollary is uncomfortable
   and is the whole reason this measurement belongs on prod: **a healthy,
   low-backlog system is MORE exposed, not less.**
3. **KV and SSE under the gateway's real traffic** — real logins writing the
   session and request buckets — rather than a synthetic client.
4. **Whether `ehdb_events_cursor_errors` stays 0 at prod event rates.** It was 0
   across 6840 kind events, but prod previously saw **26**
   ([ai-meta#216](https://github.com/noetl/ai-meta/issues/216), closed as a
   diagnosability issue, not as a cause found).

### P2a — an in-cluster sampler that survives the writer dying

**The kind rig's blocking problem:** it read the writer's `:9102` through
`kubectl port-forward`. The forward dies with the pod, so the last sample
before a kill is already stale — `reopened_tip` came back *higher* than
`tip_at_kill` (8053 > 8048), and the arithmetic could not resolve a loss
smaller than the sampling window's growth. It reported a meaningless 0.

**The fix: sample from inside the cluster, and make the output outlive the
writer.** A tiny Job in the same namespace scrapes the writer's ClusterIP
directly and writes to **stdout**, so the record survives in the container log
regardless of what happens to the writer. No port-forward anywhere in the
measurement path.

```yaml
# p2a-sampler.yaml — apply with: K apply -f p2a-sampler.yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: ehdb-soak-sampler
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: sampler
          image: curlimages/curl:8.8.0
          command: ["/bin/sh", "-c"]
          args:
            - |
              # 5 Hz for SOAK_SECS. stdout only: the log outlives the writer.
              # :9102 and :9106 are plain HTTP /metrics. NEVER touch 9104/9107/9108.
              end=$(( $(date +%s) + ${SOAK_SECS:-1800} ))
              while [ "$(date +%s)" -lt "$end" ]; do
                ts=$(date +%s.%N)
                for face in 9102 9106; do
                  curl -s --max-time 2 "http://${WRITER}:${face}/metrics" \
                    | grep -E '^(ehdb_feed_shard_(committed|lag|resume_[a-z_]+)|ehdb_feed_subject_lag|ehdb_l0_(appends|out_of_order_appends)|ehdb_events_(group_committed|group_lag|cursor_errors))' \
                    | sed "s|^|${ts} ${face} |"
                done
                sleep 0.2
              done
          env:
            - { name: WRITER,    value: "noetl-cmdbus-writer-0" }   # <- P0 name
            - { name: SOAK_SECS, value: "1800" }
```

Harvest with `K logs job/ehdb-soak-sampler > p2-samples.txt`. Delete the Job
when done. **Never** point this at 9104 / 9107 / 9108.

Two harness traps from the kind rig, both of which produced *false passes*:

- `GROUPS` is a bash special variable (the caller's Unix gids). Assigning to it
  is silently dropped. Do not use that name.
- Exact-matching a metric name fails on a labelled series
  (`ehdb_feed_shard_resume_from{shard="0",origin="persisted"}`) and returns
  `NA` — which, treated as a pass, is exactly what is being guarded against.
  Match on `name{` prefix.

### P2b — throughput and dispatch latency at prod concurrency

Method (as used for the #205 gate): measure `command.issued → command.claimed`
from the durable log via `GET /api/ehdb/executions/{id}/events`. Run three
regimes and label them honestly:

| Regime | Concurrency | Measures |
| :-- | :-- | :-- |
| Unsaturated | ≤ pool slots | the **bus** |
| At capacity | ≈ pool slots | bus + queueing onset |
| Burst | ≫ pool slots | the **pool**, not the bus — report it as such |

Reference points to compare against, all from the durable record:

| Baseline | p50 | p95 | p99 |
| :-- | --: | --: | --: |
| NATS at T4 (2026-07-27, n=90) | 338 ms | 511 ms | 520 ms |
| EHDB at T4 | 285–557 ms | — | ~1040 ms |
| EHDB post-#205/#208 (2026-07-30, n=60, unsaturated) | **138.5 ms** | 156.4 ms | 181.0 ms |

**Gate:** unsaturated p50 ≤ ~200 ms (i.e. still comfortably inside the NATS
envelope it replaced) and no regression against the 138.5 ms reference beyond
measurement noise. A burst row that shows queueing is **not** a failure — label
it "pool queueing, not bus", as the #205 report did, and record the pool's slot
count alongside it so the number is interpretable.

### P2c — the unsealed-window bound, without destroying anything ✅ default

This is the honest measurement of the exposure, and it costs nothing:

**The exposure at any instant is `tip − committed` per shard, capped at
`seal_max_records` (1024) — a ceiling; the writer was measured sealing at
20-140 records on 2026-08-04, so typical exposure is tens (noetl/ai-meta#209).**
Sample it continuously through P2b's load and
report the distribution — max, p99, and the fraction of time it exceeds 0.

```
exposure(t) = min(1024, ehdb_feed_shard_lag{shard=N})          # command bus
exposure(t) = min(1024, ehdb_events_group_lag{group=...} max)  # events feed
```

From the P2a sample file this is a one-liner. It answers the real question —
*how many acked-but-unrecoverable records would a crash cost prod right now* —
without producing that crash. The kind soak could not answer it because its
lag sat above 1024 the whole time; at prod's low backlog the number is small,
which is precisely why the exposure is real there and invisible in kind.

**Gate:** record max and p99 exposure per shard. There is no pass/fail — this
is the number [ai-meta#209](https://github.com/noetl/ai-meta/issues/209)'s
remaining half is scoped against, and it is what tells you whether the L0
active-part replay work is urgent or not.

### P2d — the destructive hard-kill measurement — *** REQUIRES HUMAN GO-AHEAD ***

*** Run only after explicit human go-ahead. Wait phrase: `run the prod hard-kill`. ***

**Read this before asking for that go-ahead.**

A SIGKILL of the writer deliberately destroys the unsealed tail — that is the
thing being measured. On prod that tail is **real records**, and the events
half of it is worse than the command half:

- Lost **commands** are recovered: the orphaned-command guardrail re-issues
  them ~30 s later.
- Lost **events** are not. The server runs
  `NOETL_EVENT_INGEST_PUBLISH_ONLY=true` and writes **zero** `noetl.event` rows;
  the materializer draining the events feed is the **sole writer** of the
  durable log. An events record lost from an unsealed part before any group
  consumed it never reaches `noetl.event`.

`noetl.event` being append-only and the platform's source of truth is a
standing constraint. **P2d can violate it.** The deterministic bound is already
known from the unit tests in `noetl/worker`
`tests/cmdbus_writer_graceful_shutdown.rs`: with the seal, **300/300** acked
records survive; without it, **0/300** — the entire unsealed active part, up to
1024 records per shard — the **ceiling**; measured 2026-08-04 the writer seals
at 20-140 records, so typical exposure is tens (noetl/ai-meta#209). P2c gives
the live prod value of that window at no
cost.

**Recommendation: do not run P2d.** P2c plus the unit-test bound answers the
question. If it is run anyway, it should be with eyes open, in a quiet window
with load stopped, and the loss accepted as intentional.

If authorized, the method that actually resolves a number (unlike the kind
attempt):

```bash
# 1. stop all load. wait for a STABLE tip: 4 consecutive identical samples
#    from the P2a log (0.2s apart), on BOTH :9102 and :9106.
# 2. record stable_tip = committed + lag, per face, from the sampler log.
# 3. SIGKILL:
K delete pod <writer-pod> --grace-period=0 --force --wait=false
# 4. the sampler keeps running and keeps logging — it is a separate pod and
#    there is no port-forward to drop. It records the gap and then the resume.
# 5. after the writer is back:
#    reopened_tip        = ehdb_feed_shard_resume_tip
#    resumed_from        = ehdb_feed_shard_resume_stored
#    clamped             = label on ehdb_feed_shard_resume_stored
#    UNSEALED_TAIL_LOST  = stable_tip - reopened_tip
```

The quiesce is what makes the arithmetic unambiguous: with no traffic in
flight, `reopened_tip` cannot exceed `stable_tip`, so a negative or zero result
means "no loss" rather than "the sample was stale".

**Rollback: there is none.** Lost records are lost. This is why the phase is
gated and why P2c exists.

### P2e — KV and SSE under the gateway's real traffic

The kind rig drove `:9107` with a synthetic client (`kv-exercise.py`) because
it has no gateway. Prod does, and the gateway's session cache and request store
are the real workload.

```bash
# during P2b's load, with real logins happening:
#   - SSE frame delivery to live SPA subscribers (frame counts must be EQUAL
#     across concurrent subscribers — it is a broadcast face; unequal counts
#     mean competing-consumer behaviour, which is wrong)
#   - gateway error rate
#   - ehdb_events_cursor_errors on :9106, sampled by P2a
K logs deploy/noetl-gateway --since=30m | grep -Ei 'ERROR|KV unreachable|SSE'
```

> One benign log line to expect: `ERROR: EHDB KV unreachable` if the gateway
> booted while the writer was rolling. It is a one-shot startup probe and the
> client redials lazily — verified recovering on its own during the NATS
> removal. The line is more alarming than the condition.

**Gate:** `ehdb_events_cursor_errors == 0` across the whole soak (prod
previously saw 26); SSE subscriber frame counts identical; gateway error rate
at baseline; 0 KV value mismatches on read-back.

### P2 overall gate

```
published == projected
  AND every enabled group's cursor advanced by that delta, ending at lag 0
  AND ehdb_events_cursor_errors == 0
  AND ehdb_l0_out_of_order_appends == 0
  AND 0 duplicate ids, 0 publish errors
  AND every SSE subscriber saw the same frame count
  AND unsaturated dispatch p50 within the NATS envelope
```

### P2 rollback

P2a/b/c/e are observational — stop the load, delete the sampler Job. If P2b
reveals a latency regression against the 138.5 ms reference, roll back per P1
and stop; do not proceed to P4.

---

## P3 — IaC plan

`action=plan` renders every object and server-side dry-runs it. **It changes
nothing.** Run it, then read the diff — that is the entire point of this phase.

> **Run this from the ops#245 branch at `5e28543` or later.** Everything below
> assumes the P0 hardening commit. On `9dcc5dd` or earlier the defaults for
> `state_builder`, the three `claim_*` names, `user_pool_container`, the gateway
> location and `writer_memory_limit` are all wrong for prod, and the writer
> Service's stale selector is not repaired — see
> [What changed after P0](#what-changed-after-p0) below.

```bash
cd repos/ops    # on branch feat/ehdb-only-iac (ops#245) until it merges

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
```

### What changed after P0

P0 found the IaC would have broken or misconfigured prod on six counts. All six
are fixed in ops@`5e28543` by making the **default** prod's measured value, so
the command line above is shorter than the one this section used to carry — the
overrides moved into the playbook. That is safer to run and more dangerous to
trust: a default is invisible at the call site, so the plan diff is now the only
place these values get checked.

| Default | Now | Was | **Confirm against prod in the plan diff** |
| :-- | :-- | :-- | :-- |
| `state_builder` | `offserver` | `server` | `NOETL_STATE_BUILDER=offserver` appears in the server patch **and both** system-pool patches. Prod runs the off-server builder; `server` would switch it off. |
| `writer_claim_cmdbus` | `noetl-cmdbus-writer-0-data` | `noetl-cmdbus-writer-data` | `claimName:` in the rendered StatefulSet, against `K get pvc`. |
| `writer_claim_eventbus` | `noetl-eventbus-writer-0-data` | `noetl-eventbus-writer-data` | same |
| `writer_claim_kv` | `noetl-eventbus-kv-0-data` | `noetl-eventbus-kv-data` | same |
| `user_pool_container` | `noetl-worker` | `worker` | the user-pool patch's `"name"` field reads `noetl-worker`, with no `NOTE … resolved to` line. A `NOTE` means the name did not match and the playbook fell back — read it, do not skim past it. |
| `gateway_namespace` / `gateway_deployment` | `gateway` / `gateway` | `noetl` / `noetl-gateway` | a `PLAN gateway` block appears at all. Its absence with `gateway_reconcile=true` is a hard error, which is the point. |
| `writer_memory_limit` | `4Gi` | `2Gi` | `limits: { cpu: "2", memory: "4Gi" }`; requests `250m` / `512Mi`. |
| `system_pool_deployment` | both pools | one pool | a `── system pool:` block for `noetl-worker-system-pool` **and** `-shard1`. |

**These are readings from 2026-08-03, not invariants.** Re-run the P0 discovery
commands and diff them against the table above before the plan; if any row has
moved, the `--set` goes back on the command line rather than the plan being
waved through.

Two things P0 inverted, and the correct answer is to change **nothing**:

- `state_shard_write` stays `true`. Prod runs all three materializer groups.
- `verify_groups` stays at all three. The earlier instruction to narrow it to
  two would have made verify read a live group as absent — and by this rig's own
  rule, unreadable is a failure, not a zero.

### The writer Service selector — found in kind, would have hit prod

`kubectl apply` is a **three-way merge**: a key on the live object that appears
in neither the applied config nor its `last-applied-configuration` annotation is
preserved by design. Prod's per-shard writer Services were created imperatively
during the cutover, so they carry no such annotation — and their existing
`app: noetl-cmdbus-writer-0` selector would have **survived** the converge,
ANDed with the pod-name selector the StatefulSet renders. The StatefulSet's pod
is labelled `app: noetl-cmdbus-writer` (no ordinal) and satisfies neither
conjunct.

Result: `Service/noetl-cmdbus-writer-0` resolves to **zero endpoints** while the
writer pod sits 1/1 Running with all nine faces listening. Everything addresses
the writer through that Service — the server's ingest, both pools' claim, the
gateway's KV and SSE, the KEDA scaler — so it is a total, silent outage behind a
green rollout. Reproduced exactly that way in kind on 2026-08-03.

ops@`5e28543` forces `/spec/selector` with a JSON patch (the only shape that can
drop a key — strategic and merge patches both merge maps), prints what it
removed, and fails the writer's status step if any per-shard Service has no
endpoints. **In the P3 plan, look for `PLAN selector on Service/… will be
REPLACED` and read the before/after.** In P4, confirm the endpoint after:

```bash
K get endpoints noetl-cmdbus-writer-0     # must list the writer pod IP
```

> Run these on `noetl` **2.17.0**. A 4.19.0 build executes the playbooks
> correctly (rc 0, steps in order) but does not print shell stdout — so the
> plan renderings and the verify verdict are invisible, which defeats the
> purpose of a plan.

### The mandatory settings, and why each one is not optional

| Setting | Why |
| :-- | :-- |
| `writer_storage_mode=claim` | The existing PVCs hold the **live command and event logs**. `template` provisions fresh volumes and strands them. This is the single most dangerous default in the whole run. |
| `writer_storage_class=premium-rwo` | The writer's durability posture is fsync-per-append — disk sync latency *is* the append-latency budget. On PD-standard a synced append is tens of ms and the bus falls outside the envelope NATS set. |
| `gateway_reconcile=true` | `auto` skips the gateway, because the kind rig has no gateway. Prod does. `true` makes an absent gateway a hard error instead of a silent skip — which is exactly what caught the wrong namespace. |
| `autoscaler_enabled=false` | P4c converges the ScaledObject separately, so a scaling anomaly and a topology anomaly cannot be confused. |
| `writer_image` digest-pinned | The P1b digest. Never a tag. |
| `profile=prod` | It is a **guard**: `prod` refuses a `kind-*` context and `kind` refuses anything else. Belt and braces on top of the explicit `context`. |

`profile` sets defaults, it does not auto-apply the four above — the usage
example in `ehdb_platform.yaml` passes every one of them explicitly for exactly
that reason. Do not assume `profile=prod` implies them.

### The two un-threaded parameters — CLOSED

Both gaps found while writing this document are fixed and no longer need a
decision:

**1. `claim_cmdbus` / `claim_eventbus` / `claim_kv` were not forwarded** from
`ehdb_platform.yaml` to `ehdb_writer.yaml`, so `--set claim_cmdbus=...` on the
entry point silently did nothing. Threaded in ops@`9dcc5dd` as
`writer_claim_cmdbus` / `writer_claim_eventbus` / `writer_claim_kv`, and their
defaults are now prod's shard-indexed names. Verified end to end in kind: the
converged StatefulSet mounts the three pre-existing PVCs by name, with **no**
`volumeClaimTemplates` and no newly provisioned volume.

**2. `state_shard_write` was not forwarded either.** Also threaded in
ops@`9dcc5dd`. The premise behind the worry was wrong in the other direction:
prod **does** run the third materializer group, so the `"true"` default is
correct and there is no silent topology change to prevent. `verify_groups`
correspondingly stays at all three — narrowing it would make verify read a live
group as `NA`, which this rig counts as a failure.

**Do not rename prod's PVCs to match the playbook.** That direction of fix is
still forbidden.

### Reading the plan — the checklist

- [ ] PVC names in the rendered StatefulSet match P0 **verbatim** —
      `noetl-cmdbus-writer-0-data`, `noetl-eventbus-writer-0-data`,
      `noetl-eventbus-kv-0-data`. And `volumes:` not `volumeClaimTemplates:`.
- [ ] `storageClassName: premium-rwo` — n/a under `storage_mode=claim` (the
      class comes from the existing PVCs); confirm the PVCs themselves are
      `premium-rwo` in P0 instead.
- [ ] Writer image is the P1b **digest**.
- [ ] Writer `limits: { cpu: "2", memory: "4Gi" }`, requests `250m` / `512Mi` —
      **not** 2Gi. A shrink here is a live workload losing headroom.
- [ ] `NOETL_STATE_SHARD_WRITE=true` on **both** system pools.
- [ ] `NOETL_STATE_BUILDER=offserver` on the server **and both** system pools.
      `server` here turns a running subsystem off.
- [ ] `NOETL_STATE_BUILDER_SHADOW=false` — prod carries no such variable, so
      this is an expected first-converge diff that rolls the system pools once.
- [ ] All four `*_SOURCE` vars render as `ehdb`, on both system pools.
- [ ] Per-pool `NOETL_FEED_FILTER_SUBJECT` matches P0 (`shared` vs `system`) —
      a wrong value silently collapses a pool onto the wrong subject and it
      stops claiming its own commands (#218).
- [ ] The user-pool patch names container `noetl-worker`, with **no**
      `NOTE … resolved to` line. A NOTE means the configured name missed.
- [ ] A `── system pool:` block appears for `noetl-worker-system-pool` **and**
      `noetl-worker-system-pool-shard1`.
- [ ] A `PLAN gateway` block appears, in namespace `gateway`, container
      `gateway`, carrying `NOETL_EVENT_FEED_ADDR` and `NOETL_KV_ADDR`.
- [ ] `PLAN selector on Service/noetl-cmdbus-writer-0 will be REPLACED` — read
      the before/after. Its absence means the selector is already exact.
- [ ] Probes point at **:9101** (`tcpSocket: { port: cmdbus-claim }`) and no
      probe points at any events face.
- [ ] `terminationGracePeriodSeconds: 60` > the 15 s shutdown budget. (Prod runs
      90 today; 60 is a reduction, still ≫ the budget.)
- [ ] Per-shard ClusterIP + headless only; **no aggregate ClusterIP**.
- [ ] The scrape object matches the CRD P0 found (`PodMonitoring` for GMP).

### Gate

The plan matches the discovery table on every line above. Any mismatch is
resolved in the playbook or the `--set` line — **never** by changing prod to
match the playbook.

### Rollback

None. `plan` changes nothing.

---

## P4 — IaC converge — ⚠ the Deployment→StatefulSet handover

**This is the most invasive phase and it is last for that reason.**

### P4a — save the rollback artefact — do this first, no exceptions

The converge's `drain_legacy` step **scales and deletes** the existing writer
Deployment so the StatefulSet can attach the RWO volumes. The PVCs survive; the
Deployment's spec does not. Recreating it later is possible **only from a saved
manifest**.

```bash
mkdir -p rollback-$(date +%Y%m%d)
K get deploy -l app=noetl-cmdbus-writer -o yaml > rollback-*/writer-deployment.yaml
K get svc -l app=noetl-cmdbus-writer -o yaml > rollback-*/writer-services.yaml
K get pvc -o yaml                            > rollback-*/pvcs.yaml
K get scaledobject -o yaml                   > rollback-*/scaledobjects.yaml
K get deploy -o yaml                         > rollback-*/all-deployments.yaml
```

Verify the saved Deployment YAML actually contains the writer's env block,
ports, volumeMounts and probes before continuing. A truncated save is a rollback
that does not work.

### P4b — converge writer + runtime, autoscaler deferred

Quiet window. The writer pod drops once.

**The exact command. It is the P3 line with `plan` → `converge` and nothing
else changed** — deliberately, so that what you read in the plan is what runs.
Run it from `repos/ops` on ops#245 at `5e28543` or later, on `noetl` **2.17.0**.

```bash
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
```

No `--set state_builder=…`, no `--set verify_groups=…`, no
`--set user_pool_container=…`, no `--set gateway_namespace=…`, no
`--set writer_claim_*=…`, no `--set writer_memory_limit=…`. Every one of those
is now the **default**, carrying prod's value measured on 2026-08-03.

**Values that MUST be re-confirmed against prod before this runs**, because they
are defaults and therefore invisible on the command line — all of them read out
of the P3 plan diff, cross-checked against a fresh P0 sweep:

| Value | Default | Confirm with |
| :-- | :-- | :-- |
| `NOETL_STATE_BUILDER` | `offserver` | `K get deploy noetl-server-rust noetl-worker-system-pool noetl-worker-system-pool-shard1 -o json \| jq -r '..\|objects\|select(.name=="NOETL_STATE_BUILDER").value'` |
| the three PVC names | shard-indexed | `K get pvc` |
| user-pool container | `noetl-worker` | `K get deploy noetl-worker-rust -o jsonpath='{.spec.template.spec.containers[*].name}'` |
| gateway location | ns `gateway`, Deployment `gateway` | `kubectl --context "$CTX" get deploy -A \| grep -i gateway` |
| writer memory limit | `4Gi` | `K get deploy noetl-cmdbus-writer-0 -o jsonpath='{.spec.template.spec.containers[0].resources}'` |
| both system pools present | list of two | `K get deploy \| grep system-pool` |
| `NOETL_STATE_SHARD_WRITE` | `true` | same jq shape as the first row |

If any of them has moved since P0, put the correct value back on the command
line as an explicit `--set` — do **not** edit prod to match the playbook.

**What the drop costs.** Commands issued in the window are re-issued by the
orphaned-command guardrail ~30 s later, so it is survivable — but it is a real
interruption, not a no-op. With worker#211 in place (P1), the SIGTERM path now
seals both the command **and** the events log before exit, which is what makes
this handover safe. Do not run P4 on a pre-#211 image.

**During the drop, `POST /api/execute` may return HTTP 500.** Fail-closed;
every accepted execution completes.

### Verification and gate

The one that matters most — **the durable log survived the handover**:

```bash
# tip continuity: the reopened engine must not have gone backwards
K exec sts/noetl-cmdbus-writer -c noetl-worker -- \
  sh -c 'wget -qO- localhost:9102/metrics' | grep -E 'resume_(from|tip|stored|replay_records)'
# origin must be "persisted" (not "fallback_tail"), clamped=false
```

| Gate | Pass |
| :-- | :-- |
| Pod names | `noetl-cmdbus-writer-0` — the names prod already resolves |
| PVCs | **the same PVC objects as P0**, not newly provisioned. `K get pvc` shows no new `creationTimestamp`, and the StatefulSet has `volumes:` with the three claim names, **no** `volumeClaimTemplates`. |
| **Service endpoints** | `K get endpoints noetl-cmdbus-writer-0` lists the writer pod IP. Empty here is a total silent outage behind a green rollout — see [the selector section](#the-writer-service-selector--found-in-kind-would-have-hit-prod). The playbook's own writer-status step fails on this now. |
| Resume | `origin="persisted"`, `clamped=false` |
| Log continuity | reopened tip ≥ the last pre-drop sample |
| Faces | all nine listening, read from inside the pod |
| State builder | `NOETL_STATE_BUILDER=offserver` still on the server and both system pools; `:9108` still has a client |
| Verify verdict | `VERDICT: PASS` on the paired evidence, with **all three** group cursors advancing by the published delta |
| Idempotence | a second `converge` bumps **no** `.metadata.generation` and restarts no pod |

Idempotence check:

```bash
K get sts,deploy -o jsonpath='{range .items[*]}{.kind}/{.metadata.name} gen={.metadata.generation}{"\n"}{end}'
```

> A re-apply prints the StatefulSet as `configured` — that is cosmetic.
> `volumeClaimTemplates` get server-side defaults so the patch is never
> byte-empty. `.metadata.generation` is the thing to check.

### P4b rollback

```bash
K scale sts/noetl-cmdbus-writer --replicas=0
K wait --for=delete pod -l app=noetl-cmdbus-writer --timeout=180s
K apply -f rollback-*/writer-deployment.yaml
K apply -f rollback-*/writer-services.yaml
K rollout status deploy/noetl-cmdbus-writer-0 --timeout=600s
```

The PVCs are never deleted by the playbook (`teardown` keeps them too), so the
durable log is intact across the rollback — **provided `storage_mode=claim` was
used.** If `template` was used by mistake, the StatefulSet provisioned *new*
volumes and the original PVCs are still there but unattached; the rollback
above reattaches them, and everything written to the StatefulSet's fresh
volumes in the interim is on the wrong disk. That is the failure this phase's
loudest warning exists to prevent.

### P4c — converge the autoscaler, separately

This is a live change to how the user pool scales. Separated from P4b so a
scaling anomaly and a topology anomaly cannot be confused.

```bash
noetl run automation/ehdb/ehdb_autoscaler.yaml -r local \
  --set action=converge \
  --set context=gke_shastaratech-noetl-prod_us-central1_noetl-prod-autopilot \
  --set enabled=true --set paused=false \
  --set pool_subject="commands.shared.shard.0" \
  --set min_replicas=2 --set max_replicas=20 --set monitoring=auto
```

Three things to know:

- **The user pool has had no autoscaling since 2026-07-26.** A *paused*
  ScaledObject makes KEDA 2.15 **delete the HPA** and stop the scaler loop
  entirely, while still looking configured — `.status.externalMetricNames` goes
  on naming whatever it named before (#210). Converging this is an improvement
  independent of everything else in this runbook.
- **The old NATS trigger is not a harmless no-op.** Its JetStream consumer held
  messages undelivered at the cutover, so the backlog was frozen rather than
  draining; unpausing with it present makes KEDA — which takes MAX across
  triggers — ask for ~15 replicas unconditionally and forever. The rendered
  object has exactly one `metrics-api` trigger and no NATS trigger.
- **`metrics-api`, not `prometheus`.** Prod monitoring is Google Managed
  Prometheus: there is no in-cluster PromQL endpoint, and both ways to give
  KEDA one need a new `monitoring.*` IAM grant. `metrics-api` scrapes the
  writer's `:9102` over the same ClusterIP the workers already claim through,
  so autoscaling does not depend on the monitoring pipeline being healthy.

**Gate:** an **HPA exists** (`K get hpa` — its absence is the #210 signature);
`ehdb_feed_subject_lag{subject="commands.shared.shard.0"}` is readable; replicas
respond to load and settle back to `min_replicas` when it stops.

**Rollback:** `K apply -f rollback-*/scaledobjects.yaml`, or delete the
ScaledObject and pin replicas with `K scale deploy/noetl-worker-rust
--replicas=2`. Note that `paused: "true"` is a **deliberate rollback**, not a
way to stage a change — it removes autoscaling entirely.

---

## P5 — post-converge re-verify and watch

1. Re-run the P2b latency measurement on the new topology. The StatefulSet
   should be latency-identical to the Deployment (same binary, same volumes,
   same faces) — a difference means something moved that should not have.
2. Watch one full autoscaler cycle: idle → load → scale-up → drain →
   scale-down to `min_replicas`.
3. Re-read `ehdb_events_cursor_errors` after 24 h. Prod's historical 26 is the
   thing to watch for; #216 was closed on diagnosability, not on a root cause.
4. Confirm a second `converge` is a clean no-op (generation unchanged).

---

## Irreversible steps

| Step | What crosses a line | Mitigation |
| :-- | :-- | :-- |
| **P1d** roll — writer pod drop | The bus is down for the pod-restart window. **No NATS fallback exists.** `POST /api/execute` may 500. | Quiet window. Orphaned-command guardrail re-issues ~30 s later. Redial measured ~2.7 s. |
| **P2d** hard SIGKILL | **Destroys the unsealed tail by design.** Lost *events* never reach `noetl.event` — the server writes zero rows under `PUBLISH_ONLY`, so the materializer is the sole writer. This can permanently lose source-of-truth records from an append-only log. | **Do not run.** P2c measures the exposure without triggering it; the unit tests give the bound (300/300 with the seal, 0/300 without). Human go-ahead required; no rollback exists. |
| **P4b** `drain_legacy` deletes the writer Deployment | The Deployment spec is gone. Recovery depends entirely on the P4a saved YAML. | P4a is mandatory and must be verified non-truncated before the converge. |
| **P4b** writer pod drop | Same as P1d, plus it is the first drop on a novel workload shape. | Requires worker#211 already deployed (P1) — that is what makes the seal happen at all. |
| **P4b** the writer Service selector | `kubectl apply`'s three-way merge KEEPS the pre-existing `app:` selector key, ANDing it with the new pod-name selector. The Service then resolves to **zero endpoints** while the pod is 1/1 Running — a total silent outage behind a green rollout, cutting off server, both pools, gateway and KEDA at once. | ops@`5e28543` forces `/spec/selector` with a JSON patch and reports what it removed; the writer status step fails when a per-shard Service has no endpoints. Confirm `K get endpoints noetl-cmdbus-writer-0` after the converge. |
| **P4b** with `storage_mode=template` (a mistake, not a step) | Provisions fresh volumes and **strands the live command and event logs**. | `claim` is mandatory and is on the P3 checklist twice. `shard_count=1` is enforced by the playbook when `claim` is set. |
| **P4c** unpausing the ScaledObject | Live change to replica counts on a pool that has not autoscaled since 2026-07-26. | Separate phase, separate gate, saved ScaledObject YAML for rollback. |
| Any `tcpSocket` probe or `nc -z` against :9104 / :9107 / :9108 | **Permanently kills that face**, silently, for the life of the process (ehdb#311). A k8s probe does it every period, forever. | Never connect to those ports. Read liveness from the pod's listening sockets. Writer probes point at :9101 and must not be repointed. |
| Any `kubectl patch --type merge` on the writer | Replaces the `containers` array wholesale — wipes env, ports, volumeMount, probes. Happened during the #205/#208 roll. | Always `--type strategic` (the default). |

---

## What the current PR/issue state changes about the plan

Findings from reading the actual PRs, playbooks and branch source while writing
this, in descending order of impact:

1. ~~**`state_shard_write` and the `claim_*` PVC names are not threaded.**~~
   **CLOSED** — threaded in ops@`9dcc5dd`, and the P0 sweep then found six more
   defaults that disagreed with prod, all fixed in ops@`5e28543` and
   kind-validated. The `state_shard_write` worry was inverted: prod **does** run
   the third materializer group, so the `true` default is right and
   `verify_groups` stays at all three. See
   [What changed after P0](#what-changed-after-p0).
2. **worker#211's `Cargo.toml` still reads `5.91.2`, an already-published
   tag.** `verify-version` hard-fails on a tag/Cargo mismatch. Bump to 5.92.0
   before merging, or the release job will not run.
3. ~~**`verify_groups` defaults to all three materializer groups**, one of which
   prod does not run.~~ **WRONG PREMISE, corrected by P0** — prod runs all
   three (`:9106` shows `noetl_state_materializer` live at lag 0). The default
   is correct; *narrowing* it is what would have failed, by reading a live group
   as absent.
4. **The hard-kill measurement is more dangerous on prod than the kind write-up
   implies.** In kind it only ever risked test data. On prod, under
   `NOETL_EVENT_INGEST_PUBLISH_ONLY=true`, a lost events tail is a permanent
   hole in `noetl.event` — the append-only source of truth. P2c replaces it as
   the default; P2d is gated and recommended against.
5. **worker#211's ehdb pin is `ddb7ac9`, which contains no fix for ehdb#311.**
   The face supervision in #211 is a *detection* mitigation (an ERROR line when
   an accept loop ends), not a cure. The operational rule — never connect to
   9104/9107/9108 — still applies in full after this deploy.
6. **`publish-ar` will fail red on the release run** (ai-meta#211, blocked on a
   human IAM grant). Expected, decoupled, cannot block the release. The crane
   path is the deploy path.
7. **The `194-l1-t4-prod-iac/rollback.sh` referenced by earlier runbooks is
   dead.** It rolls the bus back to NATS, which no longer exists in the code or
   the cluster. Every rollback here is image or topology only.
8. **Prod's ScaledObject state is genuinely unknown** — #194 applied an
   EHDB-lag scaler *paused*, then the 08-01 NATS deletion happened. Which
   trigger is on the object right now must be read, not assumed. It is in the
   P0 table for that reason.

## Related

- [ai-meta#222](https://github.com/noetl/ai-meta/issues/222) — the IaC gap (P3/P4)
- [ai-meta#221](https://github.com/noetl/ai-meta/issues/221) — fail-loud bus source (P1)
- [ai-meta#209](https://github.com/noetl/ai-meta/issues/209) — the seal (P1) and the hard-kill half (P2c/P2d)
- [ai-meta#211](https://github.com/noetl/ai-meta/issues/211) — publish-ar (P1b)
- [ai-meta#210](https://github.com/noetl/ai-meta/issues/210) — the paused-ScaledObject failure (P4c)
- [ehdb#261](https://github.com/noetl/ehdb/issues/261) — Phase 2, the soak (P2)
- [ehdb#311](https://github.com/noetl/ehdb/issues/311) — the face-killing connect
- [noetl/worker#211](https://github.com/noetl/worker/pull/211) · [noetl/ops#245](https://github.com/noetl/ops/pull/245)
- [`playbooks/220-ehdb-only-kind-soak/`](../220-ehdb-only-kind-soak/) — the kind soak this extends
- [`playbooks/205-208-prod-rollout/`](../205-208-prod-rollout/) — the prior prod roll, source of the deploy order and the merge-patch warning
- [`playbooks/211-t3-events-migration/`](../211-t3-events-migration/) — the cutover and the NATS removal
