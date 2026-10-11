# C2 — shard election rollout (noetl/ai-meta#460)

Staged 2026-10-11. **Nothing here has been run.** Every step is read-only until
P2, and P2 onward is owner-gated.

Prereq: **noetl/worker#353 merged**, a worker release tagged, and its image
published to Artifact Registry. #352 (the lease store) merged → **v6.3.0**; the
driver is what mints, so v6.3.0 alone is not enough.

⚠⚠ **`NOETL_EHDB_FENCING` is unset (= `off`) and stays unset.** C3 is not part of
this rollout. Election must be live and *minting*, verified on the scrape, before
enforce is ever considered — a fence enforces *against* an epoch.

## Facts, read from prod 2026-10-11

| | |
| :-- | :-- |
| context | `gke_shastaratech-noetl-prod_us-central1_noetl-prod-autopilot` |
| workload | `sts/noetl-cmdbus-writer`, ns `noetl`, replicas 1, RollingUpdate |
| container | **`noetl-worker`** |
| image | `…/noetl/noetl-worker-rust@sha256:2084ac3a…` (v6.2.4) |
| metrics | `:9090` (`WORKER_METRICS_BIND=0.0.0.0:9090`) |
| serviceAccountName | **unset** → runs as `default` (the only workload in `noetl` that does) |
| limits | cpu 2, memory **12Gi** (OOM history — do not reduce) |

## P0 — baseline (read-only)

```bash
PROD=gke_shastaratech-noetl-prod_us-central1_noetl-prod-autopilot
D=playbooks/460-c2-election-rollout/baseline
mkdir -p "$D"

kubectl --context "$PROD" -n noetl get sts noetl-cmdbus-writer -o json > "$D/sts-before.json"
kubectl --context "$PROD" -n noetl get pod noetl-cmdbus-writer-0 -o json > "$D/pod-before.json"

# the digest to roll BACK to
jq -r '.spec.template.spec.containers[0].image' "$D/sts-before.json" | tee "$D/rollback-image.txt"

# dispatch health, so "did the roll hurt anything" is answerable afterwards
kubectl --context "$PROD" -n noetl get pods -l 'app in (noetl-worker-rust,noetl-worker-system-pool)' \
  -o custom-columns='NAME:.metadata.name,READY:.status.containerStatuses[0].ready,RESTARTS:.status.containerStatuses[0].restartCount' > "$D/pools-before.txt"
```

⚠ The metrics baseline needs a port-forward, and **`kubectl port-forward` fails
open**: if the local port is already bound, `curl` silently talks to whatever
cluster owns it. Use an unusual local port and *prove* the target in the body.

```bash
kubectl --context "$PROD" -n noetl port-forward pod/noetl-cmdbus-writer-0 19090:9090 >/dev/null 2>&1 &
PF=$!; sleep 3
curl -sf localhost:19090/metrics > "$D/metrics-before.txt"; kill $PF

# ⚠ PROVE it is the writer and which build, or the reading is unattributable.
grep -E 'build_info|ehdb_election_' "$D/metrics-before.txt"
```

Expected before: `ehdb_election_active 0`, `ehdb_election_epoch 0` — and on
v6.2.4 the other election series are **absent entirely**, because that build
predates them. Absence is how you tell "old build" from "election off".

## P1 — RBAC (new objects; no workload change, no roll)

Apply `rbac.yaml` from this directory. Review it first — it is 3 objects.

```bash
kubectl --context "$PROD" -n noetl diff -f playbooks/460-c2-election-rollout/rbac.yaml
kubectl --context "$PROD" -n noetl apply -f playbooks/460-c2-election-rollout/rbac.yaml
```

Then confirm the grant is exactly what was intended, from the API's own view:

```bash
for v in get list watch create update delete; do
  printf '  %-7s ' "$v"
  kubectl --context "$PROD" auth can-i "$v" leases.coordination.k8s.io \
    -n noetl --as=system:serviceaccount:noetl:noetl-cmdbus-writer
done
```

⚠ **`delete` must print `no`.** Deleting a Lease discards `leaseTransitions`, so
the next acquisition re-mints epoch 1 — and a *reused* epoch is worse than no
epoch, because the store then accepts a superseded writer as current.

⚠ Also confirm `default` did **not** gain the grant (it would cover every pod in
the namespace that defaults its SA):

```bash
kubectl --context "$PROD" auth can-i create leases.coordination.k8s.io \
  -n noetl --as=system:serviceaccount:noetl:default    # must be: no
```

## P2 — the single combined roll (SA + image together) ⚠ owner-gated

One patch, so one roll. `IMG` is the **digest** of the release that contains
noetl/worker#353 — never a tag.

⚠⚠ **Do not use `--type merge`.** JSON-merge *replaces* the `containers` array
and would drop every other field on the container. The default strategic merge
patches by the `name` key. And the name must be exactly `noetl-worker` — a wrong
container name leaves a reconcile **half-applied** while reporting success.

```bash
IMG=us-central1-docker.pkg.dev/shastaratech-noetl-prod/noetl/noetl-worker-rust@sha256:<NEW>
PATCH='{"spec":{"template":{"spec":{"serviceAccountName":"noetl-cmdbus-writer","containers":[{"name":"noetl-worker","image":"'"$IMG"'"}]}}}}'
```

Before applying, diff the **whole pod template**, not the two fields changed —
a dry-run answers only the question you ask it, and that gap is where the
2026-09-08 outage lived:

```bash
kubectl --context "$PROD" -n noetl patch sts noetl-cmdbus-writer \
  --dry-run=server -o json -p "$PATCH" > /tmp/sts-after.json
diff <(jq -S '.spec.template' "$D/sts-before.json") <(jq -S '.spec.template' /tmp/sts-after.json)
```

Expect exactly two hunks: `serviceAccountName` added, `image` changed. Anything
else — a volume, a mount, a probe, a resource — stop.

```bash
kubectl --context "$PROD" -n noetl patch sts noetl-cmdbus-writer -p "$PATCH"
```

## P3 — convergence gate

```bash
kubectl --context "$PROD" -n noetl rollout status sts/noetl-cmdbus-writer --timeout=300s
kubectl --context "$PROD" -n noetl get pod noetl-cmdbus-writer-0 \
  -o custom-columns='READY:.status.containerStatuses[0].ready,RESTARTS:.status.containerStatuses[0].restartCount,START:.status.startTime'
```

**Abort criteria — roll back at P5 if any hold:**

- `restartCount` ≥ 2 within 10 minutes (restart loop);
- the pod does not reach Ready inside 5 minutes;
- worker pools report `EHDB claim connect failed` — this writer hosts **both**
  buses, so a writer that cannot serve stops dispatch fleet-wide;
- `kubectl get events` shows `FailedScheduling` (the 2026-09-08 shape: a declared
  volume whose PVC does not exist).

⚠ The restart hazard recorded for this writer is **stale** — it rolled cleanly to
v6.2.4 on 2026-10-10 (`restarts=0`). It is still the riskiest step here, because
one process hosts both buses.

Election is still **off** at this point. Confirm the new build is running and the
election is deliberately inert:

```bash
# expect: build version advanced; ehdb_election_active 0; the NEW series present at 0
grep -E 'build_info|ehdb_election_' /tmp/metrics-after-roll.txt
```

That the new series are now **present and zero** (rather than absent) is what
distinguishes "new build, election off" from "old build". It is the positive
control for P4's proof.

## P4 — flag on, then the shadow proof ⚠ owner-gated

A second pod-template change, hence a second roll. Deliberately separate: it
makes the transition observable instead of a single reading.

```bash
kubectl --context "$PROD" -n noetl set env sts/noetl-cmdbus-writer NOETL_EHDB_ELECTION=true
kubectl --context "$PROD" -n noetl rollout status sts/noetl-cmdbus-writer --timeout=300s
```

**The proof** — epochs actually minted:

```bash
kubectl --context "$PROD" -n noetl port-forward pod/noetl-cmdbus-writer-0 19090:9090 >/dev/null 2>&1 &
PF=$!; sleep 3; curl -sf localhost:19090/metrics | grep ehdb_election_; kill $PF
```

Pass requires **all** of:

| series | required |
| :-- | :-- |
| `ehdb_election_active` | `1` |
| `ehdb_election_epoch` | **≥ 1** — this is the minting claim |
| `ehdb_election_holds_lease` | `1` |
| `ehdb_election_token_valid` | `1` |
| `ehdb_election_errors_total{reason="forbidden"}` | `0` — non-zero means the Role is not bound |
| `ehdb_election_last_contact_age_seconds` | `≥ 0` and `<` lease duration (**not `-1`**, which means never) |

Cross-check against the API server, not only the scrape — two independent views:

```bash
kubectl --context "$PROD" -n noetl get lease -o custom-columns=\
'NAME:.metadata.name,HOLDER:.spec.holderIdentity,TRANS:.spec.leaseTransitions,RENEW:.spec.renewTime'
```

Expect one `ehdb-shard-00000000`, `holderIdentity` = `noetl-cmdbus-writer-0#<uuid>`,
`leaseTransitions` ≥ 1, and `renewTime` advancing on repeat reads.

⚠ Then leave it alone and re-read after **≥ 10 renew intervals** (~1 min).
`outcomes_total{outcome="renewed"}` must climb while `epoch` stays **constant** —
a renewal that advanced the epoch would make the store fence the holder against
itself. ⚠ And volume is not duration: one reading proves acquisition, not
stability.

## P5 — rollback

```bash
# flag only
kubectl --context "$PROD" -n noetl set env sts/noetl-cmdbus-writer NOETL_EHDB_ELECTION-

# flag + SA + image, back to the recorded baseline
kubectl --context "$PROD" -n noetl patch sts noetl-cmdbus-writer --type json -p \
  '[{"op":"remove","path":"/spec/template/spec/serviceAccountName"}]'
kubectl --context "$PROD" -n noetl set image sts/noetl-cmdbus-writer \
  noetl-worker="$(cat "$D/rollback-image.txt")"
kubectl --context "$PROD" -n noetl rollout status sts/noetl-cmdbus-writer --timeout=300s
```

The RBAC objects can stay — unused permissions on an SA nothing references are
inert. Remove them only if the rollout is abandoned.

⚠ Rolling back does **not** undo a Lease that was created. That is fine and must
not be "cleaned up": `leaseTransitions` is the monotonic fencing token, and
deleting the object resets it to 1. Leave it.
