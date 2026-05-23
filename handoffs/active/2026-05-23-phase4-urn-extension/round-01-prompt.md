---
thread: 2026-05-23-phase4-urn-extension
round: 1
from: claude
to: claude
created: 2026-05-23T00:15:00Z
status: open
expects_result_at: round-01-result.md
---

# Phase 4 round 1: URN extension

> **Predecessor:** v2 spec Phase 5 closed in
> `handoffs/archive/2026-05-22-phase5-payload-ref-typed-binding/`
> (noetl v2.97.0). Phase 4 is the last remaining piece on the v2
> spec. The user's stated architectural direction (paraphrased):
>
> > "Data goes through the service domain via Cloudflare. Small
> > workers enrich with URN and route to KEDA-managed NATS
> > supercluster. Queries get redirected to data locality via the
> > catalog. The catalog work comes later — let's have URN + KEDA
> > + NATS first."
>
> Phase 4 is therefore split into three rounds:
>
> - **Round 1 (this one): URN extension.** Grow the existing
>   resource-locator scheme so it can encode the data-resource
>   kinds, locality (region/zone), and NATS-subject derivation
>   that rounds 2 + 3 + the future catalog work will depend on.
> - **Round 2: KEDA scaler.** Worker-pool autoscaler keyed off
>   NATS subject metrics — leans on round 1's
>   `to_nats_subject()`.
> - **Round 3: NATS supercluster.** Multi-cluster NATS topology;
>   subjects are derived deterministically from URNs.

This round adds **no** KEDA infrastructure, **no** NATS
supercluster configuration, **no** catalog routing logic. It's
pure URN-surface extension with the future rounds' shape locked
in.

## What this round delivers

1. `noetl/core/resource_locator.py` — extended `NoetlResourceLocator`
   with:
   - Module-level `KNOWN_RESOURCE_KINDS` taxonomy (set of valid
     top-level `kind` segments — warning-only, never rejection,
     to keep forward-compat).
   - `NoetlResourceLocator.to_nats_subject()` — canonical
     NATS-safe subject derivation (`/` → `.`, segments
     normalized to `[a-zA-Z0-9_-]`).
   - `NoetlResourceLocator.from_nats_subject(subject)` —
     round-trip parser. Reconstructs the locator from the
     subject form.
   - `NoetlResourceLocator.locality()` — convenience extraction
     returning `{cluster, node, region, zone}` for whichever
     segments are present.

2. `noetl/core/runtime/topology.py` — extended worker-locality
   plumbing:
   - `WorkerLocatorParts` gains `region` and `zone` fields
     (Optional[str], default None).
   - `worker_locator()` emits `region` / `zone` segments when
     supplied in the `locality` dict (placed before `cluster` →
     `node` → `worker` so the URN reads
     coarse-to-fine: `tenant/org/region/zone/cluster/node/worker`).
   - `parse_worker_locator()` recognizes the new segments and
     populates the dataclass.
   - `worker_locality_from_env()` already harvests
     `NOETL_REGION` / `NOETL_ZONE`; preserved unchanged.
   - **Back-compat:** locators without region / zone parse
     identically to today.

3. `noetl/core/resource_locator.py` — new data-resource URN
   builder helpers (stubs for the catalog/router work in a
   later round; just emit well-typed URNs today):
   - `dataset_locator(tenant_id, organization_id, dataset_id, *, region=None, zone=None, cluster_id=None)` →
     `noetl://tenant/<t>/org/<o>[/region/<r>][/zone/<z>][/cluster/<c>]/dataset/<id>`
   - `stream_locator(tenant_id, organization_id, stream_id, *, ...)` →
     `noetl://tenant/<t>/org/<o>[/...locality...]/stream/<id>`
   - `partition_locator(tenant_id, organization_id, stream_id, partition_index, *, ...)` →
     `noetl://tenant/<t>/org/<o>[/...locality...]/stream/<sid>/partition/<idx>`

4. `tests/core/test_resource_locator.py` — extended:
   - Round-trip tests for `to_nats_subject()` / `from_nats_subject()`
     across all the resource shapes (worker, dataset, stream,
     partition).
   - NATS subject character-class validation (no `/`, no
     `?`, no spaces; segments stay within `[a-zA-Z0-9_-]`).
   - `locality()` extraction tests across worker / dataset /
     stream shapes.
   - `KNOWN_RESOURCE_KINDS` taxonomy guard — unknown kinds
     parse without error but the taxonomy reports them as
     unknown (no exception).
   - Data-resource builder tests for dataset / stream /
     partition with + without locality fields.

5. `tests/core/test_runtime_topology.py` (new or extended — Phase
   A confirms whether a file exists):
   - `parse_worker_locator` round-trips region / zone.
   - `worker_locator(...)` emits the new segments only when set.
   - `as_locality()` includes region / zone when present.
   - Back-compat: existing locator strings (no region/zone)
     parse identically.

6. Wiki updates:
   - New `noetl/core/resource_locator.md` page (no dedicated page
     exists today — the locator surface has grown enough to
     warrant one per `agents/rules/wiki-maintenance.md` rule 1).
     Cover: scheme + format, known-kind taxonomy, NATS subject
     derivation, locality extraction, data-resource builders,
     cross-links to topology + frames + payload_store pages.
   - Update `noetl/core/runtime/topology.md` to document the
     new region / zone fields on `WorkerLocatorParts` +
     `worker_locator()`.
   - Update `Home.md` and `_Sidebar.md` to include the new
     resource_locator page under `noetl/core/`.

## Background

### Existing surface (verified on origin/main @ b82d58ef)

- [`noetl/core/resource_locator.py`](https://github.com/noetl/noetl/blob/main/noetl/core/resource_locator.py)
  — `NoetlResourceLocator` dataclass, strict alternating
  `key/value` segments, URL-quoting via `quote()`/`unquote()`.
  Methods: `parse`, `from_segments`, `from_pairs`, `kind`,
  `identity`, `value_after`, `pairs`, `child`, `__str__`.
- [`noetl/core/runtime/topology.py`](https://github.com/noetl/noetl/blob/main/noetl/core/runtime/topology.py)
  — `WorkerLocatorParts` (tenant_id, organization_id,
  worker_pool, cluster_id, node_id), `worker_locator()`
  builder, `parse_worker_locator()` parser,
  `worker_locality_from_env()`, locality-distance helpers
  (`locality_distance`, `locality_within`,
  `placement_evaluation`).
  `LOCALITY_DISTANCES = ("node", "zone", "region", "cluster", "any")`
  already mentions region + zone but the URN scheme doesn't
  emit them today.
- Callers (~17 files): `noetl/core/outbox.py`,
  `noetl/core/projection_store/postgres.py`,
  `noetl/core/cursor_drivers/postgres.py`,
  `noetl/core/dsl/engine/executor/events.py`,
  `noetl/server/api/frames/endpoint.py`,
  `noetl/server/api/runtime/service.py`,
  `noetl/worker/cursor_worker.py`, etc. None of them needs to
  change in this round — the extensions are additive.
- [`tests/core/test_resource_locator.py`](https://github.com/noetl/noetl/blob/main/tests/core/test_resource_locator.py)
  — 5 tests today (parse, build via pairs, URL-quote
  round-trip, scheme rejection, query / slash rejection).

### NATS subject derivation — design

NATS subjects use `.` as the segment separator and allow
`[a-zA-Z0-9_-]` in segment names (`*` and `>` are wildcards;
not legal in concrete subjects). The mapping rule for round 1:

- Replace `/` with `.`.
- Strip the `noetl://` scheme prefix.
- For each segment: keep `[a-zA-Z0-9_-]` characters; replace
  any other byte with `_` (so URL-quoted segments collapse to
  underscores — predictable, lossy for round-trip but easy to
  reason about).
- Prefix with `noetl.` so all NoETL subjects share a common
  root for NATS subject permissions / stream subject patterns.

Example:

```
noetl://tenant/acme/org/research/cluster/us-east-1/worker/cpu-01
  ↓ to_nats_subject()
noetl.tenant.acme.org.research.cluster.us-east-1.worker.cpu-01
```

`from_nats_subject()` reverses this: strips the `noetl.`
prefix, splits on `.`, rebuilds the locator from the segments.
Because the forward mapping is **lossy** (URL-quoted bytes →
`_`), round-trip is only guaranteed for locators whose
segments are already NATS-safe. Tests cover both the lossy
and lossless cases.

### Known-kind taxonomy — design

```python
KNOWN_RESOURCE_KINDS = frozenset({
    "tenant",     # worker / runtime identity (existing)
    "execution",  # playbook execution (existing — e.g.
                  # noetl://execution/<id>/result/<step>/<id>)
    "dataset",    # logical dataset for catalog routing (new)
    "stream",     # event/data stream (new)
    "partition",  # physical partition of a stream (new)
    "payload",    # content-addressed payload (new — pairs with
                  # the Phase 5 payload_store URIs)
})
```

The taxonomy is **advisory**, not enforced — parsing an
unknown kind does not raise. Expose
`NoetlResourceLocator.is_known_kind` (property → `bool`) so
catalog code can warn / log on unknown kinds without
rejecting them.

This forward-compat policy mirrors what
`payload_ref_to_dict()` does for the `kind` discriminator: new
shapes coexist without breaking older readers.

### Data-resource builders — locality placement

Locality segments go **between** tenant/org and the resource
kind so the URN reads coarse-to-fine:

```
noetl://tenant/<t>/org/<o>/region/<r>/zone/<z>/cluster/<c>/dataset/<id>
```

When a locality field is absent, its segment pair is omitted
entirely (not emitted as empty). This keeps the URN shape
stable for the common case (no locality hints set).

## Phases

### Phase A — drift check (no remote writes)

1. Re-verify `noetl/core/resource_locator.py`,
   `noetl/core/runtime/topology.py`,
   `tests/core/test_resource_locator.py` on `origin/main`.
   Flag any drift since the Phase 5 close-out.
2. Confirm whether a `tests/core/test_runtime_topology.py` file
   exists. If not, create it as part of Phase C.
3. Confirm whether `noetl/core/resource_locator.md` exists on
   the wiki — it doesn't, per the audit. Confirm Phase D
   creates it.

### Phase B — implementation

4. **Extend `NoetlResourceLocator`** —
   `noetl/core/resource_locator.py`:
   - Add `KNOWN_RESOURCE_KINDS = frozenset({...})` module-level
     constant with the six kinds above.
   - Add `NoetlResourceLocator.is_known_kind` property →
     `self.kind in KNOWN_RESOURCE_KINDS`.
   - Add module-level constants
     `_NATS_SAFE_RE = re.compile(r"[^a-zA-Z0-9_-]")` and
     `NATS_SUBJECT_ROOT = "noetl"`.
   - Add `NoetlResourceLocator.to_nats_subject(self) -> str`:
     replace any non-NATS-safe char per segment with `_`,
     prefix with `noetl.`, join with `.`.
   - Add classmethod
     `NoetlResourceLocator.from_nats_subject(cls, subject: str)`:
     strip `noetl.` prefix, split on `.`, hand to
     `from_segments`.
   - Add `NoetlResourceLocator.locality(self) -> dict[str, str]`:
     iterate `("region", "zone", "cluster", "node")`, include
     each pair when present.
   - Add data-resource builder module-level helpers (place at
     the bottom of the file alongside `build_noetl_locator` /
     `parse_noetl_locator`):
     - `dataset_locator(tenant_id, organization_id, dataset_id, *, region=None, zone=None, cluster_id=None) -> str`
     - `stream_locator(tenant_id, organization_id, stream_id, *, region=None, zone=None, cluster_id=None) -> str`
     - `partition_locator(tenant_id, organization_id, stream_id, partition_index, *, region=None, zone=None, cluster_id=None) -> str`
   - All builders build through `NoetlResourceLocator.from_pairs`
     so empty values drop out automatically.
   - Update the module `__all__` to include the new symbols.

5. **Extend `WorkerLocatorParts` + `worker_locator()`** —
   `noetl/core/runtime/topology.py`:
   - Add `region: str | None = None` and `zone: str | None = None`
     to `WorkerLocatorParts`.
   - `as_locality()` includes region / zone when set.
   - `worker_locator(...)` emits `region` and `zone` segments
     after `tenant/org` and before `cluster`. Maintains the
     coarse-to-fine order:
     `tenant/org/region/zone/cluster/node/worker`.
   - `parse_worker_locator(...)` accepts the new segments
     under the same `unknown = sorted(set(parts) - {...})`
     check; extend the allowlist.
   - `WorkerLocatorParts` populated from `parts.get("region")`
     / `parts.get("zone")`.

### Phase C — tests

6. Extend `tests/core/test_resource_locator.py`:
   - `test_known_kind_taxonomy` — parametrized: each known
     kind has `is_known_kind == True`; an unknown kind parses
     OK but reports `is_known_kind == False`.
   - `test_to_nats_subject_round_trip_for_nats_safe_segments` —
     worker / dataset / stream / partition locators all
     round-trip through `to_nats_subject` /
     `from_nats_subject`.
   - `test_to_nats_subject_collapses_unsafe_chars` — locator
     with a segment like `"r&d"` produces a subject with `_`
     in place of `&`; explicit assertion of the lossy
     mapping.
   - `test_to_nats_subject_prefix_is_noetl` — every subject
     starts with `noetl.`.
   - `test_from_nats_subject_rejects_missing_prefix` —
     `from_nats_subject("foo.bar")` raises
     `ResourceLocatorError`.
   - `test_locality_extracts_present_segments` — locator with
     region + zone + cluster returns the right dict; missing
     segments are absent from the dict.
   - `test_locality_returns_empty_for_no_locality_segments` —
     `noetl://execution/123` → `locality() == {}`.
   - `test_dataset_locator_builds_canonical_shape` — with +
     without locality.
   - `test_stream_locator_builds_canonical_shape` — with +
     without locality.
   - `test_partition_locator_includes_stream_id_and_index` —
     emits `stream/<id>/partition/<idx>`.

7. New file `tests/core/test_runtime_topology.py` (or extend
   existing — Phase A confirms which):
   - `test_worker_locator_emits_region_and_zone` —
     `locality={"region": "us-east1", "zone": "us-east1-b"}`
     produces a URN with `/region/us-east1/zone/us-east1-b/`
     in the right position.
   - `test_parse_worker_locator_populates_region_and_zone` —
     parses the URN above; `parts.region == "us-east1"`,
     `parts.zone == "us-east1-b"`.
   - `test_worker_locator_without_locality_unchanged` —
     existing call signature still produces the legacy URN
     (no region/zone segments).
   - `test_worker_locator_parts_as_locality_includes_region_zone`
     — `parts.as_locality()` carries region/zone when set.
   - `test_parse_worker_locator_rejects_unknown_segment` —
     a locator with `country/uk` still raises
     `ResourceLocatorError` (the allowlist is enforced).

8. Run:
   ```
   .venv/bin/python -m pytest tests/core/test_resource_locator.py
         tests/core/test_runtime_topology.py -q
   .venv/bin/python -m pytest tests/core/test_resource_locator.py
         tests/core/test_runtime_topology.py
         tests/core/test_event_store_ports.py
         tests/core/event_store/
         tests/core/payload_store/
         tests/core/test_replay_payload_ref_locator_kind.py -q
   ```
   All green.

### Phase D — wiki update

9. Create `repos/noetl-wiki/noetl/core/resource_locator.md`.
   Sections:
   - Purpose + scheme.
   - URN structure (alternating key/value).
   - `NoetlResourceLocator` API table (parse, from_segments,
     from_pairs, kind / identity / value_after / pairs / child,
     locality, to_nats_subject, from_nats_subject,
     is_known_kind).
   - Known-kind taxonomy (the frozenset, advisory not
     enforced).
   - NATS subject derivation (rules, lossiness caveat,
     example).
   - Data-resource builders (dataset/stream/partition).
   - Cross-links to [topology](runtime/topology),
     [frames](frames), [payload_store](payload_store),
     [event_store](event_store).
   - Source link to `noetl/core/resource_locator.py` on main.

10. Update `repos/noetl-wiki/noetl/core/runtime/topology.md`:
    - Add `region` and `zone` to the `WorkerLocatorParts`
      table.
    - Update the worker-locator schema example to include
      `/region/<r>/zone/<z>/` in the canonical order.
    - Cross-link to the new `resource_locator` page.

11. Update `repos/noetl-wiki/Home.md` and `_Sidebar.md` to list
    the new `resource_locator` page under `noetl/core/`.

12. Commit + push wiki.

### Phase E — verify locally

13. Pytest is the only required gate this round. Already
    covered by Phase C.

### Phase F — open PR and merge

> ***Run only after explicit human go-ahead. Wait phrase: `merge phase 4 urn`.***

14. Push branch `kadyapam/phase4-urn-extension`, open noetl
    PR titled `feat(resource-locator): URN extension for data resources, locality, and NATS subjects`.
15. Wait for CI / human review.
16. Merge with `--admin --merge --delete-branch`.
17. Bump ai-meta pointers (noetl + noetl-wiki) and archive the
    handoff.

## FINAL REPORT

Body sections — one H2 per Phase A–F, plus `## Issues observed`
and `## Manual escalation needed`.

## Hard rules

- Never push to `origin/main` on any repo unless this prompt
  says so. Phase F is the only step that pushes, gated by
  `merge phase 4 urn`.
- Never force-push.
- Never merge PRs yourself before the gate phrase.
- Respect `agents/rules/wiki-maintenance.md` — Phase D wiki
  page is **a new page** because the locator surface grows
  enough this round to warrant one.
- Do not store secrets in any file under ai-meta.
- If a step's preconditions aren't met, stop and write the
  report with `status: blocked`.
- **No KEDA work in this round.** Round 2 covers it.
- **No NATS supercluster work in this round.** Round 3
  covers it. This round only adds the subject-derivation
  helper that round 3 will use.
- **No catalog routing in this round.** Catalog work is an
  out-of-phase follow-up after Phase 4 completes.
- **Back-compat is load-bearing.** Existing URN-emitting
  callers must not need to change. Existing URN parsers
  (`parse_worker_locator`, etc.) must still accept the old
  shape unchanged.
