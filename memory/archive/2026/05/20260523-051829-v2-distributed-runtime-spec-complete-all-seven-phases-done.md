# v2 distributed-runtime spec complete — all seven phases done
- Timestamp: 2026-05-23T05:18:29Z
- Author: Kadyapam (via Claude session)
- Tags: noetl,v2-spec,complete,milestone,phase4,nats-supercluster,distributed-runtime

## TL;DR

**The v2 distributed-runtime spec is complete across all seven
phases.** PR #595 (Phase 4 round 3, NATS supercluster topology)
closes the last open phase. NoETL reached **v2.99.0**.

## What's done (all seven phases)

| Phase | Topic | Closing PR |
|---|---|---|
| 0 | Instrumentation + stage/frame tables + replay API | — (predates this session) |
| 1 | Frame-shaped cursor loops | #585 |
| 2 | Projector StatefulSet behind NATS durable consumers | — (predates) |
| 3 | Apache Arrow IPC Tier 1.5 | #587 |
| 4 | URN + KEDA + NATS supercluster | #593 + #594 + #595 |
| 5 | Port/adapter event/projection/payload | #582–#592 (six rounds) |
| 6 | Stage planner for fanout/reduce | #588 |

## Phase 4 (this session's final phase)

Three rounds, three PRs, single afternoon:

### Round 1 — URN extension (PR #593)

Extends the `noetl://` URN scheme with the shape that rounds 2 +
3 + the future catalog routing all key off:

- `KNOWN_RESOURCE_KINDS` advisory taxonomy (tenant, execution,
  dataset, stream, partition, payload).
- `to_nats_subject()` / `from_nats_subject()` — canonical
  NATS-safe subject derivation (lossy collapse for unsafe
  chars).
- `locality()` extraction; `LOCALITY_KEYS = ("region", "zone",
  "cluster", "node")` in coarse-to-fine order.
- `dataset_locator` / `stream_locator` / `partition_locator`
  data-resource URN builders.
- `WorkerLocatorParts` gains `region` + `zone`; `worker_locator`
  emits coarse-to-fine; back-compat for URNs without those
  segments.
- New wiki page `noetl/core/resource_locator.md`.

### Round 2 — KEDA scaler (PR #594)

URN-driven `ScaledObject` generator for NATS JetStream
consumer-lag-based worker autoscaling:

- `ScaledObjectSpec` dataclass + `build_worker_scaledobject()`
  + `dump_scaledobject_yaml()`.
- Sample manifest `ci/manifests/keda/scaledobject-worker-cpu-01.yaml`
  generated verbatim; drift-guard test catches hand-edits.
- KEDA Helm install is a manual one-off step — not bundled into
  `noetl k8s deploy`.
- New wiki page `noetl/core/runtime/keda.md`.

### Round 3 — NATS supercluster (PR #595, this round)

Multi-cluster NATS topology generator:

- `ClusterTopology` + `SuperclusterTopology` dataclasses.
- `build_nats_conf()` renders the HOCON config (cluster routes
  + gateway entries + jetstream domain from URN + accounts
  preserved verbatim).
- `build_cluster_manifests()` produces ConfigMap + StatefulSet
  + headless Service.
- 2-cluster sample (`a` in `us-east-1`, `b` in `us-west-2`,
  3 pods each, mutual gateways) committed under
  `ci/manifests/nats-supercluster/`. Three drift-guard tests.
- Existing single-node `ci/manifests/nats/` deployment
  preserved; supercluster is opt-in.
- New wiki page `noetl/core/runtime/nats_supercluster.md`.

## Pattern that worked across all three Phase 4 rounds

1. **Code module** in `noetl/core/runtime/` (or
   `noetl/core/resource_locator.py` for round 1) with frozen
   dataclasses + builder functions + YAML dumper +
   URN-aware derivations.
2. **Committed sample manifest(s)** in `ci/manifests/<feature>/`
   generated verbatim by the documented snippet in the header.
3. **Drift-guard tests** loading the committed YAML, comparing
   structurally to generator output — catches any hand-edit.
4. **Manual install documented**, not automated, to keep the
   diff small + reviewable.
5. **Wiki page paired with the code change** per
   `agents/rules/wiki-maintenance.md` rule 1.

Same pattern proven through Phase 5 (cloud adapters) earlier in
the session; reusing it for Phase 4 kept each round mergeable
in under an afternoon.

## User's architectural direction (captured for future work)

> "Data flows through the service domain via Cloudflare. Small
> workers enrich with URN and route to KEDA-managed NATS
> supercluster. Queries get redirected to data locality via the
> catalog. The catalog work comes later — let's have URN + KEDA
> + NATS first."

The v2 spec now provides:

- **URN scheme** that encodes locality (region/zone/cluster/node)
  + kind (tenant/execution/dataset/stream/partition/payload).
- **KEDA scaler** that uses URN-derived consumer names + scaler
  names so multi-pool deployments don't collide.
- **NATS supercluster topology** with gateway routing between
  clusters; JetStream domains derive from URNs.
- **Payload store** with content-addressed storage across
  filesystem + S3 + GCS + Azure + SeaweedFS-via-S3 (Phase 5).

What's still needed to realize the chemistry-lab-cloud vision —
all out-of-phase follow-ups now:

- **Catalog-driven query routing** — the big architectural
  piece. Catalog dispatches queries based on the URN's
  locality segments + kind discriminator.
- **Cluster-aware NATS client routing** — `NATSCommandPublisher`
  / `NATSCommandSubscriber` pick the right cluster endpoint
  per request based on URN locality.
- **Per-tenant NATS accounts** — supercluster generator extends
  to emit per-tenant `accounts {}` blocks; KEDA's `nats_account`
  carries the tenant.
- **Cross-cluster stream mirror/source** — JetStream mirrors
  configured via the gateway topology.
- **Storage-tier spill-to-payload-store wiring** —
  `TempStore`/`Storage` spill path actually routes through a
  registered `PayloadStore`.
- **PayloadStore-aware resolver routing** — replay can fetch
  `s3://` / `gs://` / `azure://` URIs through the right
  adapter.
- **Process-emulator compliance fixture** — Azurite +
  `fake-gcs-server` in a shared test-infra harness so GCS +
  Azure cloud-adapter tests join the parametrized compliance
  suite.

## Session totals (rough)

- **15 noetl PRs** (#582–#595) across two days of work covering
  Phase 5 (rounds 1–5: port + filesystem + S3 + GCS + Azure +
  payload_ref binding) and Phase 4 (rounds 1–3: URN + KEDA +
  NATS supercluster), plus the earlier Phase 1 / 3 / 6 rounds.
- **NoETL versions:** v2.93.0 → **v2.99.0** across the v2 spec
  work.
- **noetl-wiki pages added / extended:**
  - New: `payload_store`, `resource_locator`,
    `runtime/keda`, `runtime/nats_supercluster`.
  - Extended: `event_store` (`payload_ref` typed binding),
    `runtime/topology` (region/zone, autoscaling cross-link),
    `messaging` (multi-cluster cross-link).
- **Handoff threads closed:** 8 archived under
  `handoffs/archive/` (all 5 Phase 5 + all 3 Phase 4).

## Pointers (final)

- noetl: `… → ec98c85a` (v2.99.0)
- noetl-wiki: `… → a283fef`
- ai-meta: `81ce4f2` (final pointer bump + handoff archive) +
  this entry
- Handoff archive (Phase 4):
  - `handoffs/archive/2026-05-23-phase4-urn-extension/`
  - `handoffs/archive/2026-05-23-phase4-keda-scaler/`
  - `handoffs/archive/2026-05-23-phase4-nats-supercluster/`

## What comes next (suggested ordering)

The v2 spec is done. The next layer is the **architectural
follow-up** that turns the spec-complete platform into the
chemistry-lab-cloud product:

1. **Catalog-driven query routing** — likely the most leveraged
   single piece. Defines what a "query" looks like in the URN
   language, how the catalog maps URN → cluster endpoint, and
   how clients pick a cluster.
2. **Cluster-aware NATS client routing** — implementation of
   the above on the client side. Builds on the supercluster
   topology generator.
3. **Storage-tier spill-to-payload-store wiring** — closes the
   gap between Phase 5 and the existing `TempStore` callers.
4. **Per-tenant NATS accounts** — extends the supercluster
   generator + KEDA scaler with tenant-aware accounts.
5. **Process-emulator compliance fixture** — Azurite +
   fake-gcs-server in CI so GCS + Azure cloud adapters join
   the parametrized compliance suite.

Each is its own handoff round. The catalog work is the biggest;
the rest are 1–2-day rounds.
