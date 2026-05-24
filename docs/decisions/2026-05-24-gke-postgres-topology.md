# Decision — GKE Postgres topology

**Status:** decided (Option A)
**Owner:** Kadyapam
**Created:** 2026-05-24
**Decided:** 2026-05-24
**Unblocks:** GKE-hardening follow-up (`handoffs/active/2026-05-23-gke-playbook-hardening/` archived; new A-shaped thread to open separately)

## Context

After the v2-spec close-out (Phases 0–6 done) and the Scope A/B
manifest consolidation, the kind cluster and the GKE cluster
deploy NoETL through two different paths:

| Cluster | Postgres | NATS | Worker image | Deploy mechanism |
|---|---|---|---|---|
| `kind-noetl` (local) | ops-manifest `deployment/postgres` on a `Retain` PV | ops-manifest single-pod `StatefulSet` | locally built + `kind load` | `noetl run automation/development/noetl.yaml` |
| `noetl-cluster` (GKE) | **Helm-deployed Cloud SQL + PgBouncer** | Helm-deployed single-pod | Artifact Registry tag | **Helm release**, unrelated to `automation/development/noetl.yaml` |

This divergence surfaced during codex's GKE validation round
(2026-05-23). The dev playbook is local-kind-shaped: it assumes
Podman / kind image loading, applies static `hostPath` PVs,
and bakes in the existing `ci/manifests/...` paths. None of that
runs cleanly on GKE Autopilot.

To make the GKE deploy first-class, we need to decide whether the
GKE cluster should converge **onto** the ops-manifest topology
(so the dev playbook is the single deploy path everywhere) or
whether the dev playbook should grow GKE-specific branches that
target the existing Helm / Cloud SQL stack.

## Option A — keep Helm + Cloud SQL on GKE

GKE retains its current Helm-managed shape: Cloud SQL Postgres,
PgBouncer in front, NATS via Helm chart, noetl-server / worker
deployed via Helm chart.

The kind cluster keeps the ops-manifest `deployment/postgres`
stack and the dev playbook.

To unblock the playbook-hardening round, we make the dev
playbook **GKE-aware**: add a `--set target=gke` flag that swaps
in registry images, skips test-server, applies dynamic PVCs, and
parameterizes the NATS account / endpoint that KEDA reads from.

### Pros

- **Production-grade Postgres.** Cloud SQL gives us automatic
  backups, point-in-time recovery, IAM auth, HA, automatic
  minor-version patches. The ops-manifest Postgres is a
  single-pod with a `hostPath` PV — fine for kind, not for any
  long-running cluster.
- **PgBouncer pooling.** The Helm chart already provisions a
  proper connection pool that all noetl-server / projector /
  outbox-publisher pods share. On the ops-manifest topology
  each pod opens its own pool against Postgres directly.
- **Zero re-provisioning cost.** Existing GKE cluster has data
  + history. Stays as-is.
- **Helm chart can keep evolving** independently of the
  application repo — the chart is the GKE deploy spec.

### Cons

- **Two deploy paths to maintain.** kind ↔ GKE parity becomes a
  permanent maintenance burden. Every new ops manifest in
  `noetl/ops/ci/manifests/` has to be mirrored as a Helm
  template, or the playbook needs to know not to apply it
  on GKE.
- **The dev playbook stays mostly kind-specific.** A
  `target=gke` branch helps but the bulk of the deploy logic
  on GKE lives in the Helm chart, which is a separate artifact.
- **Operational doc fragmentation.** Two install guides
  (kind via playbook; GKE via Helm). Two sets of operator
  knowledge.
- **Account / credential drift can keep happening.** The KEDA
  scaler manifest assumed `account: NOETL`; the Helm NATS
  has it in `$G`. The supercluster generator assumed the
  ops-manifest accounts block; the Helm NATS has a different
  one. Each new addition risks the same divergence.

## Option B — converge GKE onto the ops-manifest topology

GKE re-provisioned to use the ops-manifest deploy path: drop
Cloud SQL + PgBouncer, replace with `deployment/postgres` on a
dynamically-provisioned `standard-rwx` PVC (or pd-balanced
RWO). Drop the Helm NATS, use the ops-manifest `StatefulSet`.
Worker / server / projector / outbox-publisher all deploy via
`noetl run automation/development/noetl.yaml --runtime local
--set target=gke ...`.

The dev playbook gets GKE storage-class overlays, registry-only
image strategy, and a `target=gke` branch that skips the
podman-machine check + uses dynamic PVCs. **No `target=helm`
branch.**

### Pros

- **Single deploy path.** kind ↔ GKE ↔ EKS ↔ Bare-metal all
  use the same playbook + the same manifests. New ops surface
  lands once, applies everywhere.
- **Manifest consolidation pays off fully.** Scope A + B were
  predicated on `noetl/ops/ci/manifests/` being the source of
  truth. With Option B that's actually true. Option A
  partially undoes it for GKE.
- **No more account / endpoint divergence** between clusters —
  KEDA scaler, supercluster generator, worker config all use
  the same shape everywhere.
- **Catalog-routing design** (next major v2 successor) keys off
  the URN scheme + ops manifests; it gets to assume a single
  topology.

### Cons

- **Lose Cloud SQL benefits.** Backups, PITR, IAM auth, HA,
  managed upgrades all become operator responsibilities again.
  Single-pod Postgres on dynamic PVC won't tolerate node loss
  cleanly.
- **Re-provisioning cost.** Catalog + execution history on the
  current GKE cluster either gets migrated (Cloud SQL →
  in-cluster Postgres dump/restore — feasible but
  non-trivial) or wiped.
- **Need to add HA Postgres later.** A real production GKE
  deploy needs either an operator (Zalando, CrunchyData) or
  back to Cloud SQL eventually. We'd be deferring HA into a
  future round.
- **PgBouncer goes away unless we add it to the manifests.**
  Higher per-pod connection count against the single Postgres,
  unless we wire pgbouncer in as another ops-manifest.
- **NATS supercluster on a single GKE node is the same CPU
  pressure** the local kind cluster hit — needs cluster_size
  tuning or multi-node Autopilot config.

## Option C — defer the decision, make the dev playbook GKE-tolerant only for the operational manifests

This is a compromise: the dev playbook learns enough about GKE
to apply the **KEDA scaler** and **NATS supercluster** manifests
correctly there (account / endpoint parameterization, dynamic
PVCs, image-tag handling), but leaves the existing Helm
Cloud SQL + Helm NATS / Helm noetl-server alone.

### Pros

- **Smallest scope.** No re-provisioning. No new operator
  knowledge. The dev playbook on GKE deploys only the
  application-side manifests that aren't already managed by
  the Helm chart.
- **Unblocks the regression-testing path.** KEDA scaler +
  supercluster can be provisioned via the playbook against the
  existing Helm cluster.
- **Decision can be revisited.** Doesn't preclude Option A or B
  later.

### Cons

- **Two deploy paths still exist.** The Helm chart deploys
  noetl-server / worker / projector / outbox-publisher /
  postgres / nats; the playbook adds KEDA + supercluster.
- **Manifest divergence continues** for the application-shaped
  pieces (server / worker / etc.) — there are two sources of
  truth.
- **Codex's "Issues observed" stay open**: env tuning between
  Helm and ops-manifest workers (NOETL_DISABLE_METRICS,
  inflight limits, etc.) doesn't converge.

## My recommendation

**Option C (defer)** for now, with an explicit plan to revisit
within ~1 quarter once the catalog-routing design round
clarifies whether single-cluster Postgres is realistic
production target.

Rationale:
- Option B's "lose Cloud SQL" is too aggressive for a target
  that's already in use.
- Option A's two-permanent-paths cost is real but tolerable
  short-term.
- Option C is the smallest unblock for the playbook-hardening
  round and doesn't lock us in.

If you choose A or B, the work is bigger and lands as its own
multi-round effort. Option C can wrap up in a single
playbook-hardening round.

## How to decide

Pick one of A / B / C, write it inline below this header in
this file, commit, and the `gke-playbook-hardening` round can
move forward.

### Decision

```
Option: A — keep Helm + Cloud SQL on GKE
Rationale: Cloud SQL gives production-grade Postgres (PITR, IAM
auth, HA, managed upgrades) and PgBouncer is already pooling
connections cluster-wide. The two-paths maintenance cost is real
but acceptable; kind stays on the ops-manifest dev playbook for
local iteration, and the Helm chart is the canonical GKE deploy
spec. Revisit only if catalog-routing or multi-cluster work
forces a single topology.
Decided by: Kadyapam
Date: 2026-05-24
```

## Consequences

Locked in as of 2026-05-24:

- **GKE deploy spec = Helm chart** at `repos/ops/automation/helm/noetl/`.
  Cloud SQL + PgBouncer stays. The dev playbook does **not** grow a
  `target=gke` branch.
- **kind deploy spec = `automation/development/noetl.yaml`** with
  ops-manifest Postgres on a hostPath PV.
- **KEDA `ScaledObject`** for GKE should become a first-class chart
  artifact (currently applied as an external file with live
  patches). The chart needs to template the account / monitoring
  endpoint / stream / consumer correctly for the Helm NATS shape.
- **HPA conflict** already fixed (ops PR #115; `worker.autoscaling.enabled`
  defaults to `false` in the GKE provision playbook).
- **Worker durable consumer drift** already addressed (noetl PR #600
  `_recover_fetch_subscription` self-heal).
- **Operational wiki split**: `noetl/ops` wiki documents the Helm + Cloud
  SQL path for GKE; `noetl/noetl` wiki keeps the application API/DSL
  reference. The kind / dev-playbook install also lives in `noetl/ops`.
- **Stale Pending PVCs** in the GKE `noetl` and `postgres` namespaces
  remain cleanup-eligible (cosmetic).

## Follow-up threads to open

A fresh handoff thread under the A profile will scope:

1. Promote external KEDA `ScaledObject` to a chart-templated artifact
   (parameterize account, monitoring endpoint, stream, consumer).
2. Wiki: write `noetl/ops/wiki/gke-helm-install` covering Cloud SQL +
   PgBouncer + KEDA + supercluster.
3. Document the dev playbook scope: "kind only — not for GKE." Add a
   guard or doc note.
4. PgBouncer connection budget docs in the ops wiki.
5. Stale Pending PVCs cleanup recipe.

The original `2026-05-23-gke-playbook-hardening` thread was framed
before this decision (item 4 of its round-01 was "decide topology"),
so it's archived rather than continued. The new thread will be
scope-clean.
