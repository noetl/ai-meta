---
thread: 2026-05-23-phase4-keda-scaler
round: 1
from: claude
to: claude
created: 2026-05-23T04:50:00Z
status: open
expects_result_at: round-01-result.md
---

# Phase 4 round 2: KEDA scaler

> **Predecessor:** Phase 4 round 1 closed in
> `handoffs/archive/2026-05-23-phase4-urn-extension/` (PR #593,
> noetl `ffcbb31d`). The URN scheme now carries the locality +
> NATS-subject derivation that this round keys off.

This round adds a **KEDA scaler** that drives the existing
`noetl-worker` Deployment based on NATS JetStream consumer lag.
Subjects + consumer names derive from worker-pool URNs (via
round 1's `to_nats_subject()` / `_locality_pairs` helpers) so a
future multi-pool deployment can spin up scalers
programmatically without copy-pasting YAML.

This is a **code + manifest + wiki round, with no live kind
validation**. Live KEDA install + scale-up smoke is gated on the
human running `noetl k8s deploy` (see `agents/rules/ops-deploy.md`)
and is captured as the Phase F manual escalation step.

## What this round delivers

1. `noetl/core/runtime/keda.py` — new module with:
   - `ScaledObjectSpec` frozen dataclass capturing the inputs
     to a KEDA `ScaledObject` (target Deployment name +
     namespace, min/max replicas, polling + cooldown,
     `lagThreshold`, NATS endpoint, stream / consumer / account).
   - `build_worker_scaledobject(worker_pool_urn, *, deployment, namespace, ...)`
     — produces a plain dict matching the KEDA v1alpha1
     `ScaledObject` schema for the `nats-jetstream` scaler.
   - URN-aware derivations:
     - The KEDA object name defaults to
       `<deployment>-scaler-<nats-safe-segment>` so multiple
       worker pools don't collide.
     - The NATS consumer name defaults to
       `NoetlResourceLocator.from(...).to_nats_subject()`
       (minus the `noetl.` prefix) when the caller doesn't
       override it, so the URN → consumer mapping is the
       canonical, single source of truth.
   - `dump_scaledobject_yaml(spec_dict) -> str` — render
     helper using `yaml.safe_dump`. Stable key ordering so
     diffs are reviewable.

2. `ci/manifests/keda/` — new manifest directory:
   - `README.md` — covers (a) one-time KEDA install via Helm
     (`helm install keda kedacore/keda --namespace keda --create-namespace`),
     (b) what this directory's manifests do, (c) the human
     `noetl k8s deploy` workflow.
   - `scaledobject-worker-cpu-01.yaml` — concrete `ScaledObject`
     for the existing single-pool `noetl-worker` Deployment.
     Generated using `build_worker_scaledobject(...)` and
     committed as the canonical reference output; the YAML
     header notes which call produced it.

3. `tests/core/runtime/test_keda.py` — unit tests for the
   generator. No KEDA cluster required.

4. Wiki page `noetl/core/runtime/keda.md` — new dedicated page
   per `agents/rules/wiki-maintenance.md` rule 1. Covers the
   `ScaledObjectSpec` shape, URN-derived defaults, sample
   manifest, install + verification commands. Cross-links to
   [Resource Locator](resource_locator) and
   [Runtime Topology](topology).

5. Wiki updates: `Home.md` and `_Sidebar.md` list the new
   `keda` page under `noetl/core/runtime/`.

## What this round does NOT do

- **No live KEDA install.** Cluster-side install is a
  human-driven one-time setup; the round documents it but
  doesn't automate it. The PR body lists the expected
  `helm install` + `noetl k8s deploy` commands so the human
  can dry-run them.
- **No worker Deployment changes.** The existing
  `ci/manifests/noetl/worker-deployment.yaml` (`replicas: 3`)
  stays; KEDA takes over scaling once installed, but the
  Deployment manifest itself is untouched in this round to
  keep the diff small and reviewable.
- **No round 3 (NATS supercluster) work.** Single-cluster NATS
  remains the baseline. The scaler's `natsServerMonitoringEndpoint`
  points at the existing `nats.nats.svc.cluster.local:8222`.
- **No catalog-driven dynamic scaling.** A future round can
  iterate worker-pool URNs from the catalog and spin up
  scalers programmatically; this round just provides the
  generator function so the future round has the shape to
  call.

## Background

### Verified existing surface (on origin/main @ ffcbb31d)

- `ci/manifests/noetl/worker-deployment.yaml` — single
  Deployment named `noetl-worker`, namespace `noetl`, labeled
  `worker-pool: worker-cpu-01`, `replicas: 3`. This is the
  target of the round-2 ScaledObject.
- `ci/manifests/noetl/configmap-worker.yaml` — the worker
  reads `NATS_STREAM=NOETL_COMMANDS`, `NATS_CONSUMER=noetl_worker_pool`,
  `NATS_SUBJECT=noetl.commands`. The round-2 scaler points at
  the same `(stream, consumer)` pair.
- `ci/manifests/nats/nats.yaml` — single NATS server with
  JetStream enabled. Monitoring port `8222` exposed inside the
  cluster as `nats.nats.svc.cluster.local:8222`. KEDA's
  `nats-jetstream` scaler reads from this monitoring port.
- `ci/manifests/keda/` — does **not** exist yet. This round
  creates it.
- `noetl/core/resource_locator.py` (round 1) — provides
  `to_nats_subject()`, `KNOWN_RESOURCE_KINDS`, locality
  segments. Round 2 leans on `to_nats_subject()` for consumer
  naming.
- No `keda` page on the wiki today.

### KEDA `nats-jetstream` scaler — schema reference

```yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: noetl-worker-scaler-cpu-01
  namespace: noetl
spec:
  scaleTargetRef:
    name: noetl-worker
  minReplicaCount: 1
  maxReplicaCount: 20
  pollingInterval: 10
  cooldownPeriod: 30
  triggers:
    - type: nats-jetstream
      metadata:
        natsServerMonitoringEndpoint: "nats.nats.svc.cluster.local:8222"
        account: "$G"
        stream: "NOETL_COMMANDS"
        consumer: "noetl_worker_pool"
        lagThreshold: "10"
        activationLagThreshold: "1"
        useHttps: "false"
```

`account: "$G"` is the NATS default-account marker (Global).
`lagThreshold` is the number of pending messages per replica
above which KEDA scales up. `activationLagThreshold` is the
minimum pending count to start scaling at all (KEDA's
`min → 0` activation knob, but we keep `minReplicaCount: 1` so
the activation just gates above-baseline scaling).

### URN → KEDA name derivations

The generator derives names from a worker-pool URN so future
multi-pool deployments don't collide:

| KEDA field | Default | Example |
|---|---|---|
| `metadata.name` | `<deployment>-scaler-<pool-segment>` | `noetl-worker-scaler-cpu-01` |
| `consumer` | last NATS-safe segment of the URN OR the existing `NATS_CONSUMER` env value when overridden | `noetl_worker_pool` (for the existing deployment) or `cpu-01` (for a fresh pool) |
| `stream` | constant `NOETL_COMMANDS` for round 2 | (single-stream baseline) |

For the canonical sample committed to
`ci/manifests/keda/scaledobject-worker-cpu-01.yaml`, the
generator is called with `consumer="noetl_worker_pool"`
explicitly so the manifest matches the **existing**
`configmap-worker.yaml` (which still names the consumer
`noetl_worker_pool`). The URN-derived defaults are exercised
by the unit tests so future pool spin-ups get fresh consumer
names automatically.

## Phases

### Phase A — drift check (no remote writes)

1. Re-verify `ci/manifests/noetl/worker-deployment.yaml`,
   `ci/manifests/noetl/configmap-worker.yaml`,
   `ci/manifests/nats/nats.yaml` on `origin/main`. Flag any
   drift since the Phase 4 round 1 close-out.
2. Confirm `pyyaml` is on the runtime dep list (used by
   `dump_scaledobject_yaml`). If not, capture for Phase B.
3. Confirm no existing `noetl/core/runtime/keda*` module —
   `runtime/` already contains `topology.py` + `retry.py`; the
   new module is a sibling.

### Phase B — implementation

4. **Generator module** —
   `noetl/core/runtime/keda.py`:
   - Module docstring covering scope (round 2 of Phase 4),
     out-of-scope items (no install automation, no Deployment
     changes), cross-references to round 1's URN scheme.
   - Constants:
     - `DEFAULT_LAG_THRESHOLD = 10`
     - `DEFAULT_ACTIVATION_LAG_THRESHOLD = 1`
     - `DEFAULT_POLLING_INTERVAL_SECONDS = 10`
     - `DEFAULT_COOLDOWN_SECONDS = 30`
     - `DEFAULT_MIN_REPLICAS = 1`
     - `DEFAULT_MAX_REPLICAS = 20`
     - `DEFAULT_NATS_STREAM = "NOETL_COMMANDS"`
     - `DEFAULT_NATS_MONITORING_ENDPOINT = "nats.nats.svc.cluster.local:8222"`
     - `DEFAULT_NATS_ACCOUNT = "$G"`
   - `ScaledObjectSpec` frozen dataclass:
     - `worker_pool_urn: str` (required)
     - `deployment: str` (required)
     - `namespace: str = "noetl"`
     - `scaler_name: Optional[str] = None` (derived if None)
     - `min_replicas: int = DEFAULT_MIN_REPLICAS`
     - `max_replicas: int = DEFAULT_MAX_REPLICAS`
     - `polling_interval_seconds: int = DEFAULT_POLLING_INTERVAL_SECONDS`
     - `cooldown_seconds: int = DEFAULT_COOLDOWN_SECONDS`
     - `nats_monitoring_endpoint: str = DEFAULT_NATS_MONITORING_ENDPOINT`
     - `nats_account: str = DEFAULT_NATS_ACCOUNT`
     - `nats_stream: str = DEFAULT_NATS_STREAM`
     - `nats_consumer: Optional[str] = None` (derived if None)
     - `lag_threshold: int = DEFAULT_LAG_THRESHOLD`
     - `activation_lag_threshold: int = DEFAULT_ACTIVATION_LAG_THRESHOLD`
   - `build_worker_scaledobject(spec: ScaledObjectSpec) -> dict[str, Any]`:
     - Parses the URN; validates the `kind` is `"tenant"`
       (worker-pool URN shape) — raise `ValueError` otherwise.
     - Derives the worker-pool segment as the last NATS-safe
       segment of the URN.
     - When `spec.scaler_name is None`: derive as
       `f"{spec.deployment}-scaler-{worker_pool_segment}"`.
     - When `spec.nats_consumer is None`: derive as the URN's
       NATS subject form minus the `noetl.` prefix and with
       `.` → `_` (so the consumer name is a single NATS
       identifier).
     - Validates `min_replicas >= 0`, `max_replicas >= min_replicas`,
       `lag_threshold > 0`, `polling_interval_seconds > 0`,
       `cooldown_seconds > 0`. Raise `ValueError` on violation
       with a clear message naming the offending field.
     - Returns a `dict` matching the KEDA v1alpha1
       `ScaledObject` schema (see Background section).
   - `dump_scaledobject_yaml(scaledobject: dict[str, Any]) -> str`:
     - Returns a YAML string via
       `yaml.safe_dump(scaledobject, sort_keys=False)` so the
       structural ordering above survives.
   - `worker_pool_segment(worker_pool_urn: str) -> str` helper
     — exported separately so callers can use it for label
     selectors etc. without rebuilding the full ScaledObject.
   - `__all__` lists every public symbol.

5. **Sample manifest** —
   `ci/manifests/keda/scaledobject-worker-cpu-01.yaml`:
   - Generated by calling the round-2 generator and saved
     verbatim. The YAML header comment notes:
     - The exact `build_worker_scaledobject(...)` call that
       produced it.
     - "Regenerate via `python -m noetl.core.runtime.keda --help`
       once the CLI lands" — placeholder note since no CLI
       lands this round.
     - The Phase 4 round-2 reference.

6. **Manifest README** —
   `ci/manifests/keda/README.md`:
   - One-time KEDA install (`helm install keda kedacore/keda
     --namespace keda --create-namespace --version 2.15.x`).
   - Apply the sample manifest:
     `kubectl apply -f ci/manifests/keda/scaledobject-worker-cpu-01.yaml`.
   - Verification commands:
     `kubectl get scaledobject -n noetl`,
     `kubectl get hpa -n noetl` (KEDA creates an HPA),
     `kubectl describe scaledobject noetl-worker-scaler-cpu-01 -n noetl`.
   - Pointer to the wiki page for the full design.
   - Note that KEDA install + apply is **not** part of the
     stock `noetl k8s deploy` flow yet; it's a manual one-off.

### Phase C — tests

7. New file `tests/core/runtime/test_keda.py`:
   - `test_build_worker_scaledobject_uses_urn_for_scaler_name`
     — confirms the `metadata.name` follows
     `<deployment>-scaler-<pool-segment>`.
   - `test_build_worker_scaledobject_derives_consumer_from_urn`
     — when `nats_consumer is None`, the consumer is the
     URN's NATS subject form minus the `noetl.` prefix and
     with `.` → `_`.
   - `test_build_worker_scaledobject_honors_explicit_consumer`
     — explicit `nats_consumer="noetl_worker_pool"` survives.
   - `test_build_worker_scaledobject_emits_keda_v1alpha1_schema`
     — asserts the dict has `apiVersion: keda.sh/v1alpha1`,
     `kind: ScaledObject`, `spec.scaleTargetRef.name` matches
     `deployment`, `spec.triggers[0].type == "nats-jetstream"`,
     all stream/consumer/lagThreshold metadata strings are
     stringified (KEDA requires strings even for numeric
     fields).
   - `test_build_worker_scaledobject_rejects_non_tenant_urn`
     — passing an `execution/...` or `dataset/...` URN raises
     `ValueError`.
   - `test_build_worker_scaledobject_rejects_invalid_replica_counts`
     — `max_replicas < min_replicas`, `min_replicas < 0`,
     each raise `ValueError`.
   - `test_build_worker_scaledobject_rejects_zero_lag_threshold`
     — `lag_threshold=0` raises.
   - `test_build_worker_scaledobject_with_full_locality`
     — URN with region/zone/cluster all set; consumer name
     reflects each segment.
   - `test_dump_scaledobject_yaml_round_trip`
     — `yaml.safe_load(dump_scaledobject_yaml(d)) == d`.
   - `test_dump_scaledobject_yaml_preserves_top_level_key_order`
     — `apiVersion` before `kind` before `metadata` before
     `spec` in the serialized form.
   - `test_worker_pool_segment_extracts_last_safe_segment`
     — helper extraction test (no full ScaledObject).
   - `test_sample_manifest_matches_generator_output` — load
     `ci/manifests/keda/scaledobject-worker-cpu-01.yaml`,
     compare structurally to the generator output for the
     documented call. Drift guard: if anyone hand-edits the
     sample manifest, the test catches it.

8. Run:
   ```
   .venv/bin/python -m pytest tests/core/runtime/test_keda.py -q
   .venv/bin/python -m pytest tests/core/runtime/ tests/core/test_resource_locator.py
         tests/core/test_runtime_topology.py -q
   ```
   All green.

### Phase D — wiki update

9. Create `repos/noetl-wiki/noetl/core/runtime/keda.md`:
   - Section: **Purpose** — autoscale worker pools based on
     NATS JetStream lag; URN-derived names so multi-pool
     deployments don't collide.
   - Section: **`ScaledObjectSpec`** — table of every field
     with type + default + URN-derivation rules.
   - Section: **Generated `ScaledObject` schema** — the
     output dict shape annotated against the KEDA v1alpha1
     reference.
   - Section: **Sample manifest** — link to
     `ci/manifests/keda/scaledobject-worker-cpu-01.yaml` on
     main, with the exact generator call that produces it.
   - Section: **Install + verify** — `helm install keda`,
     `kubectl apply`, `kubectl get scaledobject`,
     `kubectl get hpa`. Note that KEDA install is a manual
     one-off step today.
   - Section: **Tuning** — `lagThreshold` rule of thumb,
     `activationLagThreshold` purpose,
     `pollingInterval` / `cooldownPeriod` trade-offs.
   - Section: **Related** — cross-links to
     [Resource Locator](resource_locator) for URN → consumer
     mapping, [Runtime Topology](topology) for worker pool
     identity, [Messaging](messaging) for NATS client config.

10. Update `repos/noetl-wiki/noetl/core/runtime/topology.md`
    — add a one-paragraph "Worker pools and autoscaling"
    subsection cross-linking to the new keda page.

11. Update `repos/noetl-wiki/Home.md` — new row under
    `noetl/core/runtime/` for **KEDA Scaler**.

12. Update `repos/noetl-wiki/_Sidebar.md` — list `KEDA Scaler`
    under the runtime grouping (or right after
    `Runtime Topology` if no formal grouping).

13. Commit + push wiki.

### Phase E — verify locally

14. Pytest is the only required gate. Already covered by
    Phase C.

### Phase F — open PR and merge

> ***Run only after explicit human go-ahead. Wait phrase: `merge phase 4 keda`.***

15. Push branch `kadyapam/phase4-keda-scaler`, open noetl PR
    titled `feat(runtime): KEDA scaler for NATS JetStream worker autoscaling`.
16. PR body lists:
    - Summary.
    - Manual cluster-side steps the reviewer should run
      after merge (KEDA Helm install + `kubectl apply -f
      ci/manifests/keda/scaledobject-worker-cpu-01.yaml`).
    - The verification commands.
    - Wiki paired commit.
17. Wait for CI / human review.
18. Merge with `--admin --merge --delete-branch`.
19. Bump ai-meta pointers (noetl + noetl-wiki) and archive
    the handoff.

## Manual escalation (post-merge)

This round does **not** install KEDA in any cluster. After PR
merge, the human (or a follow-up agent) should validate by:

```
# 1. Install KEDA into the existing kind cluster
helm repo add kedacore https://kedacore.github.io/charts && helm repo update
helm install keda kedacore/keda --namespace keda --create-namespace --version 2.15.0

# 2. Apply the sample ScaledObject
kubectl apply -f repos/noetl/ci/manifests/keda/scaledobject-worker-cpu-01.yaml

# 3. Verify
kubectl get scaledobject -n noetl noetl-worker-scaler-cpu-01
kubectl get hpa -n noetl   # KEDA creates an HPA behind the scenes

# 4. Drive load via NATS to verify scale-up
# (noetl playbook execution → NATS commands → consumer lag → KEDA scales)
```

These steps are **not** added to `noetl k8s deploy` automation in
this round; KEDA install is a one-off cluster setup.

## FINAL REPORT

Body sections — one H2 per Phase A–F, plus `## Issues observed`
and `## Manual escalation needed` (the latter inherits the
KEDA-install commands above).

## Hard rules

- Never push to `origin/main` on any repo unless this prompt
  says so. Phase F is the only step that pushes, gated by
  `merge phase 4 keda`.
- Never force-push.
- Never merge PRs yourself before the gate phrase.
- Respect `agents/rules/wiki-maintenance.md` — Phase D ships a
  new wiki page for the new `noetl/core/runtime/keda.py`
  module (rule 1).
- Do not store secrets in any file under ai-meta.
- If a step's preconditions aren't met, stop and write the
  report with `status: blocked`.
- **No live KEDA install in this round.** Manual escalation
  step only.
- **No worker Deployment edits.** Keep the diff small —
  KEDA takes over scaling once installed; the static
  `replicas: 3` stays in the Deployment manifest as a
  fallback initial value (KEDA reconciles it once installed).
- **No NATS supercluster work.** Round 3 covers it.
