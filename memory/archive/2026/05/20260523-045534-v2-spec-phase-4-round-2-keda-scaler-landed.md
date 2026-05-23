# v2 spec Phase 4 round 2 — KEDA scaler landed
- Timestamp: 2026-05-23T04:55:34Z
- Author: Kadyapam (via Claude session)
- Tags: noetl,v2-spec,phase4,keda,nats-jetstream,autoscaling,runtime,milestone

## Summary

Phase 4 round 2 adds a KEDA `nats-jetstream` scaler that drives
the existing `noetl-worker` Deployment based on JetStream consumer
lag. Subjects + consumer names derive from worker-pool URNs (via
round 1's `to_nats_subject()`) so future multi-pool deployments
can spin up scalers programmatically without copy-pasting YAML.

KEDA install + `kubectl apply` are a deliberate **manual one-off
cluster setup** — not yet bundled into `noetl k8s deploy`. The
diff stays small + reviewable; live validation is documented in
the manifest README + wiki page and can be run anytime after
merge.

PR #594 merged. **66 tests** green in the focused regression
sweep (22 new KEDA tests + 44 from the round 1 URN/topology
suite). NoETL released **v2.99.0**.

## What landed

### `noetl/core/runtime/keda.py` (new module)

- **`ScaledObjectSpec`** frozen dataclass — required fields are
  `worker_pool_urn` + `deployment`; every other field has a
  sensible default exported as a module constant
  (`DEFAULT_LAG_THRESHOLD=10`,
  `DEFAULT_NATS_MONITORING_ENDPOINT="nats.nats.svc.cluster.local:8222"`,
  `DEFAULT_NATS_ACCOUNT="$G"`, etc.).
- **`build_worker_scaledobject(spec)`** — produces a KEDA
  v1alpha1 ScaledObject `dict`:
  - Validates URN kind is `"tenant"`; other kinds raise.
  - Validates all numeric fields (`min_replicas >= 0`,
    `max_replicas >= min_replicas`, `lag_threshold > 0`,
    `polling > 0`, `cooldown > 0`, `activation >= 0`).
  - Derives `metadata.name` →
    `f"{deployment}-scaler-{worker_pool_segment(urn)}"` when
    `scaler_name is None`.
  - Derives NATS `consumer` → URN's `to_nats_subject()` body
    with `noetl.` stripped and `.` → `_` (consumer names
    disallow `.`).
  - Stringifies all trigger-metadata values (KEDA requires
    strings even for numeric `lagThreshold` etc.).
- **`dump_scaledobject_yaml(d)`** — `yaml.safe_dump(..., sort_keys=False)`
  so the `apiVersion → kind → metadata → spec` order survives
  serialization. Diffs against committed manifests stay
  reviewable.
- **`worker_pool_segment(urn)`** — exported helper returning
  the last NATS-safe segment. Reusable for label selectors etc.

### `ci/manifests/keda/`

- **`scaledobject-worker-cpu-01.yaml`** — canonical sample for
  the existing single-pool `noetl-worker` Deployment. Generated
  verbatim by the documented call (header comment shows the
  exact snippet). Explicit `nats_consumer="noetl_worker_pool"`
  matches the existing `noetl-worker-config` ConfigMap. The
  `test_sample_manifest_matches_generator_output` test catches
  hand-edits.
- **`README.md`** — KEDA Helm install (`kedacore/keda` 2.15.0),
  `kubectl apply`, verification commands, regen recipe.

### Tests — `tests/core/runtime/test_keda.py` (22)

URN-derived defaults, explicit-override path, KEDA schema
walk, label assertions, non-tenant URN rejection
(execution / dataset / payload), parametrized numeric validation
(7 invalid configs), `min_replicas=0` allowed (scale-to-zero
gate), full-locality URN → locality-rich consumer name, YAML
round-trip, top-level key-order preservation, sample-manifest
drift guard.

### Wiki

- **New page:** `noetl/core/runtime/keda.md` (rule 1 of
  `wiki-maintenance.md`).
- Updated `topology.md` with a "Worker pools and autoscaling"
  subsection cross-linking to the new page.
- `Home.md` + `_Sidebar.md` updated.

## URN → KEDA derivations

Example for the existing single-pool deployment:

```
URN:      noetl://tenant/default/org/default/worker/worker-cpu-01
subject:  noetl.tenant.default.org.default.worker.worker-cpu-01
consumer (derived): tenant_default_org_default_worker_worker-cpu-01
scaler name:         noetl-worker-scaler-worker-cpu-01
```

The committed sample manifest passes
`nats_consumer="noetl_worker_pool"` explicitly so it matches
the existing ConfigMap; fresh pools added in future rounds can
omit it and pick up the URN-derived name automatically.

## Pointers

- noetl: `ffcbb31d → f574b328` (v2.97.0 → v2.99.0; includes
  v2.98.0 release commit for PR #593's URN extension and the
  PR #594 merge `4d40fb08`)
- noetl-wiki: `e7e4842 → 91d4456`
- ai-meta: `c205c09` (pointer bump + handoff archive) + this entry
- Handoff archive: `handoffs/archive/2026-05-23-phase4-keda-scaler/`

## v2 spec status now

| Phase | Status |
|---|---|
| 0–3 | done |
| 4 — URN + KEDA + NATS supercluster | rounds 1 + 2 done; round 3 (NATS supercluster) remains |
| 5 | done |
| 6 | done |

**Phase 4 round 3 (NATS supercluster) is the only remaining
v2-spec piece.**

## Notes for next round

### Phase 4 round 3 — NATS supercluster

Decisions to make in the round 3 handoff prompt:

- **Topology shape.** Single cluster with NATS gateway
  connections to peers vs. supercluster proper (3+ clusters
  meshed). Likely supercluster for the production target but
  the kind cluster only models one node — round 3 has to
  decide whether the kind deployment becomes a single-cluster
  with a documented multi-cluster config, or whether kind
  spins up multiple NATS pods to model the multi-cluster
  case.
- **Stream replication.** Per-tenant streams? Per-region
  streams? Mirror vs. source streams? The URN's
  coarse-to-fine locality order (`region/zone/cluster`) is
  the natural sharding key.
- **Per-tenant accounts.** Round 2's KEDA scaler defaults to
  the global `$G` account. Round 3 can extend `ScaledObjectSpec`
  to carry per-tenant accounts derived from the URN tenant
  segment — likely a small follow-up commit after the
  supercluster topology lands.

### Out-of-phase: catalog-driven dynamic worker-pool spin-up

Once Phase 4 closes, the catalog work can iterate worker URNs
and call `build_worker_scaledobject` per pool to generate +
apply `ScaledObject`s programmatically. This is the data-flow
direction the user laid out:

> "Data through Cloudflare → small workers enrich with URN →
> route to KEDA-managed NATS supercluster. Queries redirect
> to data locality via the catalog."

The shape rounds 1 + 2 produced is exactly what the catalog
needs to drive both halves.

## Lessons / side observations

- **The scope-rejection step earned its keep.** Round 2's
  prompt explicitly carved out the manual KEDA install vs. the
  automatable manifest generation. Keeping the install
  manual + documenting it in README + wiki + PR body was the
  cheaper choice and avoids one-shot kind validation friction
  blocking the merge.
- **Drift-guard tests are habit-forming.** The
  `test_sample_manifest_matches_generator_output` pattern
  (load committed YAML, compare to generator output, fail on
  any divergence) prevents the slow rot of YAML-vs-code
  drift in shipped manifests. Worth applying to other
  generators that emit committed artifacts.
- **KEDA's string-only metadata requirement is easy to miss.**
  Caught explicitly in
  `test_build_worker_scaledobject_emits_keda_v1alpha1_schema`'s
  `isinstance(md["lagThreshold"], str)` assertion. Without
  the test, a future "make it an int" PR would land cleanly
  in Python but produce a manifest KEDA refuses to apply.
