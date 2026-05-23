# v2 spec Phase 4 round 1 — URN extension landed
- Timestamp: 2026-05-23T04:39:21Z
- Author: Kadyapam (via Claude session)
- Tags: noetl,v2-spec,phase4,urn,resource-locator,nats,topology,locality,milestone

## Summary

Phase 4 of the v2 spec opens with a URN-surface extension. The
`noetl://` scheme now carries the discrimination + locality +
NATS-mapping shape that the upcoming KEDA scaler (round 2),
NATS supercluster (round 3), and future catalog-driven query
routing all key off.

This round is **additive only** — no consumer rewiring, no
KEDA, no NATS infrastructure. Existing 17+ URN call sites
continue to work unchanged.

PR #593 merged. **144 tests** green in the focused regression
sweep (44 in the URN/topology file scope; 100 more across the
wider event_store + payload_store + replay-locator sweep).

## User's architectural direction (captured for future rounds)

> "Data flows through the service domain via Cloudflare. Small
> workers enrich with URN and route to KEDA-managed NATS
> supercluster. Queries get redirected to data locality via the
> catalog. The catalog work comes later — let's have URN + KEDA
> + NATS first."

Phase 4 is therefore split into three rounds:

1. **Round 1 (this one): URN extension.** Done.
2. **Round 2: KEDA scaler.** Worker-pool autoscaler keyed off
   NATS subject metrics. Subjects derived via
   `to_nats_subject()` from round 1.
3. **Round 3: NATS supercluster.** Multi-cluster NATS topology.
   Subjects + stream patterns derive deterministically from
   URNs.

Catalog-driven query routing is **out of phase** — comes after
Phase 4 closes.

## What landed

### `noetl/core/resource_locator.py`

- `KNOWN_RESOURCE_KINDS` frozenset — advisory taxonomy of
  recognized top-level kinds (`tenant`, `execution`, `dataset`,
  `stream`, `partition`, `payload`). Parsing an unknown kind
  never raises; consumers branch on `is_known_kind`. Mirrors
  the `payload_ref` `kind` discriminator pattern from Phase 5
  round 5.

- `NATS_SUBJECT_ROOT = "noetl"` constant plus
  `to_nats_subject()` / `from_nats_subject()`:
  - Maps `/` → `.`, collapses any non-`[a-zA-Z0-9_-]` char in a
    segment to `_`, prefixes with `noetl.` so NATS subject
    permissions can match `noetl.>`.
  - Lossy for non-NATS-safe segments; round-trip identity
    guaranteed only when every segment is already NATS-safe.
  - Phase 4 round 3 (NATS supercluster) keys subjects off this
    mapping.

- `LOCALITY_KEYS = ("region", "zone", "cluster", "node")` plus
  `NoetlResourceLocator.locality()` — extract present locality
  segments into a plain dict in coarse-to-fine key order.

- Module-level builders `dataset_locator` / `stream_locator` /
  `partition_locator` — typed URN constructors for the future
  catalog routing. All keyword-only locality args; empty
  values drop out through `from_pairs`.

### `noetl/core/runtime/topology.py`

- `WorkerLocatorParts` gains `region: str | None` and
  `zone: str | None`.
- `worker_locator()` emits the locality segments in
  coarse-to-fine order:
  `tenant → org → region → zone → cluster → node → worker`.
- `parse_worker_locator()` extends the allowlist; back-compat
  is load-bearing (URNs without region/zone parse identically
  and report `None`).
- `as_locality()` includes the new fields when set.

### Tests

- **30 new tests** across `tests/core/test_resource_locator.py`
  (22) and `tests/core/test_runtime_topology.py` (8):
  - Known-kind taxonomy (parametrized across all six known
    kinds + an unknown-kind guard + a set-contents wire-format
    guard).
  - NATS subject round-trip across worker / execution /
    payload / partition shapes.
  - Lossy-character-collapse explicit assertion (`r&d` →
    `r_d`, `team alpha` → `team_alpha`).
  - NATS-forbidden-char exclusion (no `/`, `*`, `>`,
    whitespace, `?`).
  - `from_nats_subject` error paths (missing prefix, empty
    body, empty input).
  - Locality extraction (full / partial / empty).
  - Data-resource builder shapes (with + without locality);
    builder → parser round-trip.
  - Worker locator emits region/zone in coarse-to-fine order.
  - `parse_worker_locator` populates the new fields +
    back-compat.
  - Unknown-segment rejection still enforced (catches
    `country/uk` etc.).

### Wiki

- **New page:** `noetl/core/resource_locator.md` — full
  standalone documentation per
  `agents/rules/wiki-maintenance.md` rule 1 (locator surface
  has grown enough to warrant a dedicated page).
- Updated `noetl/core/runtime/topology.md` — region / zone
  documented; coarse-to-fine emission order; cross-link to
  the new resource_locator page.
- Updated `Home.md` + `_Sidebar.md` to list the new page.

## Pointers

- noetl: `b82d58ef → ffcbb31d` (PR #593 merge `ffcbb31d`)
- noetl-wiki: `1549932 → e7e4842`
- ai-meta: `85868a5` (pointer bump + handoff archive) + this entry
- Handoff archive: `handoffs/archive/2026-05-23-phase4-urn-extension/`

## v2 spec status now

| Phase | Status |
|---|---|
| 0 — instrumentation + stage/frame tables + replay API | done |
| 1 — frame-shaped cursor loops | done |
| 2 — projector StatefulSet behind NATS durable consumers | done |
| 3 — Apache Arrow IPC Tier 1.5 | done |
| 4 — URN + KEDA + NATS supercluster | round 1 done; rounds 2 + 3 remain |
| 5 — port/adapter event/projection/payload | done |
| 6 — stage planner for fanout/reduce | done |

## Notes for next round

- **Phase 4 round 2 — KEDA scaler.** Worker-pool autoscaler
  driven by NATS JetStream stream/consumer metrics, queried
  via a KEDA `external` or `nats-jetstream` scaler. Subjects
  derived from URNs via `to_nats_subject()`. Likely needs:
  - A scaler configuration helper that produces the right
    KEDA `ScaledObject` YAML from a worker-pool URN.
  - Local kind smoke verifying KEDA + NATS reach steady-state
    scale-up + scale-down.
  - Wiki page for the scaler under
    `noetl/server/api/runtime/` or similar.
  - Round 2 is a deployment / k8s-config round more than a
    Python-code round. Lean on `repos/ops` automation per
    `agents/rules/ops-deploy.md` for the kind validation
    step.

- **Phase 4 round 3 — NATS supercluster.** Multi-cluster NATS
  topology. Decisions to make in the round 3 handoff prompt:
  - Single cluster with gateway connections vs. supercluster
    proper.
  - Stream replication strategy across clusters.
  - Per-tenant vs. per-region stream partitioning.
  - The URN's coarse-to-fine locality order is the natural
    sharding key — round 3 commits to it formally.

- **Out-of-phase: catalog-driven query routing.** Once Phase 4
  closes, the catalog work uses:
  - Locality segments on URNs to know where data lives.
  - NATS subject derivation to know which subscriber pool
    handles a request.
  - `KNOWN_RESOURCE_KINDS` for dispatcher branching.

## Lessons / side observations

- The forward-compat policy (advisory taxonomy, never reject
  unknown kinds) is now a repeated pattern across NoETL: see
  also `payload_ref_to_dict`'s `kind` discriminator from
  Phase 5 round 5. Worth surfacing as a project principle in
  a future curate pass.
- The NATS subject derivation is **deliberately lossy**. The
  alternative — error on non-NATS-safe segments — would
  break the very first non-ASCII tenant name. Lossy collapse
  + explicit caveat documentation is the right trade.
- `agents/rules/wiki-maintenance.md` rule 1 triggered cleanly
  this round: `resource_locator.py` had grown past
  one-paragraph coverage in a sibling page, so the new
  standalone wiki page shipped paired with the code change in
  the same coordination window.
