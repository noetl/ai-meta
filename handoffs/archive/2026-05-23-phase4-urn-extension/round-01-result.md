---
thread: 2026-05-23-phase4-urn-extension
round: 1
from: claude
to: claude
created: 2026-05-23T01:30:00Z
in_reply_to: round-01-prompt.md
status: partial
---

# Result — Phase 4 round 1: URN extension — round 1

Phases A through E completed. Phase F (merge) blocked on the
prompt's wait phrase `merge phase 4 urn`.

## Phase A — drift check (no remote writes)

- `noetl/core/resource_locator.py`, `noetl/core/runtime/topology.py`,
  and `tests/core/test_resource_locator.py` on `origin/main`
  matched the survey from the handoff prompt — no drift since the
  Phase 5 close-out.
- `tests/core/test_runtime_topology.py` **does exist** already
  (6 tests). Phase C extends it rather than creating a new file.
- `repos/noetl-wiki/noetl/core/resource_locator.md` is **absent**.
  Phase D creates it (per `agents/rules/wiki-maintenance.md`
  rule 1 — locator surface has grown enough to warrant a
  dedicated page).

## Phase B — implementation

- **`noetl/core/resource_locator.py`** extended:
  - Added module-level constants `NATS_SUBJECT_ROOT = "noetl"`,
    `_NATS_SAFE_RE = re.compile(r"[^a-zA-Z0-9_-]")`,
    `LOCALITY_KEYS = ("region", "zone", "cluster", "node")`,
    `KNOWN_RESOURCE_KINDS = frozenset({"tenant", "execution",
    "dataset", "stream", "partition", "payload"})`.
  - `NoetlResourceLocator.is_known_kind` property — advisory
    taxonomy check; never raises.
  - `NoetlResourceLocator.locality()` — returns `{region?, zone?,
    cluster?, node?}` in coarse-to-fine key order.
  - `NoetlResourceLocator.to_nats_subject()` — replaces non-NATS-
    safe chars with `_`, joins with `.`, prefixes with `noetl.`.
  - `NoetlResourceLocator.from_nats_subject(subject)` classmethod
    — strips prefix, splits on `.`, hands to `from_segments`.
    Raises `ResourceLocatorError` on missing prefix, empty body,
    or non-string input.
  - Module-level `dataset_locator` / `stream_locator` /
    `partition_locator` builders — all go through
    `NoetlResourceLocator.from_pairs` so empty locality kwargs
    drop out. Internal `_locality_pairs` helper centralizes the
    coarse-to-fine ordering.
  - `__all__` updated to expose every new public symbol.

- **`noetl/core/runtime/topology.py`** extended:
  - `WorkerLocatorParts` gains `region: str | None = None` and
    `zone: str | None = None`.
  - `as_locality()` includes them when set, in coarse-to-fine
    key order alongside `cluster_id` / `node_id` / `worker_pool`.
  - `worker_locator()` reads `region` and `zone` from the
    locality dict and emits the segment pairs in coarse-to-fine
    order. Comment in the source explicitly notes the ordering.
  - `parse_worker_locator()` adds `region` and `zone` to the
    allowlist; populates the new `WorkerLocatorParts` fields.
  - **Back-compat verified**: URNs without `region`/`zone`
    segments parse identically and report `None` for those
    fields (covered by
    `test_parse_worker_locator_back_compat_without_region_zone`).

- End-to-end smoke confirmed before tests:
  ```
  worker URN: noetl://tenant/acme/org/research/region/us-east1/
              zone/us-east1-b/cluster/prod/node/n-a/worker/cpu-01
  parts.region: us-east1   parts.zone: us-east1-b
  NATS subject: noetl.tenant.acme.org.research.region.us-east1
                .zone.us-east1-b.cluster.prod.node.n-a.worker.cpu-01
  Round-trip from subject: identical URN
  ```

## Phase C — tests

- **`tests/core/test_resource_locator.py`** extended with **22
  new tests**:
  - `test_known_kind_taxonomy_recognizes_each_kind` — parametrized
    across all six known kinds.
  - `test_known_kind_taxonomy_reports_unknown_without_error` —
    `spaceship/enterprise-d` parses; `is_known_kind == False`.
  - `test_known_kind_taxonomy_exports_expected_set` — guards the
    set's contents as part of the wire contract.
  - `test_to_nats_subject_round_trip_for_nats_safe_segments` —
    parametrized across worker / execution / payload / partition
    URN shapes.
  - `test_to_nats_subject_collapses_unsafe_chars` — explicit
    assertion that `r&d`/`team alpha` collapse to `r_d`/
    `team_alpha`.
  - `test_to_nats_subject_prefix_is_noetl`
  - `test_to_nats_subject_does_not_emit_nats_forbidden_chars` —
    regex assertion that the subject only contains
    `[a-zA-Z0-9_.-]`, plus explicit guards that `?`, `*`, `>`,
    and space never appear.
  - `test_from_nats_subject_rejects_missing_prefix`
  - `test_from_nats_subject_rejects_empty_body` (`"noetl."`)
  - `test_from_nats_subject_rejects_empty_input` (`""`)
  - `test_locality_extracts_present_segments`
  - `test_locality_returns_empty_for_no_locality_segments`
  - `test_locality_returns_only_set_segments`
  - `test_dataset_locator_builds_canonical_shape` (with + without
    full locality)
  - `test_dataset_locator_skips_unset_locality_fields`
  - `test_stream_locator_builds_canonical_shape`
  - `test_partition_locator_includes_stream_id_and_index`
  - `test_data_resource_locators_round_trip_through_parser` —
    every builder produces a URN the parser accepts.

- **`tests/core/test_runtime_topology.py`** extended with **8 new
  tests**:
  - `test_worker_locator_emits_region_and_zone_in_coarse_to_fine_order`
  - `test_worker_locator_emits_region_only_when_zone_unset`
  - `test_worker_locator_without_region_or_zone_is_back_compat`
    — confirms the pre-round-1 URN shape still emits when
    locality omits `region`/`zone`.
  - `test_parse_worker_locator_populates_region_and_zone`
  - `test_parse_worker_locator_back_compat_without_region_zone`
  - `test_worker_locator_parts_as_locality_includes_region_zone`
  - `test_parse_worker_locator_rejects_unknown_segment` —
    confirms the allowlist still rejects `country/uk` etc.
  - (existing tests unchanged)

- Local pytest results:

  ```
  $ pytest tests/core/test_resource_locator.py
           tests/core/test_runtime_topology.py -q --no-header
  44 passed in 0.45s

  $ pytest tests/core/test_resource_locator.py
           tests/core/test_runtime_topology.py
           tests/core/test_event_store_ports.py
           tests/core/event_store/
           tests/core/payload_store/
           tests/core/test_replay_payload_ref_locator_kind.py -q
  144 passed in 5.11s
  ```

## Phase D — wiki update

- **Created** `repos/noetl-wiki/noetl/core/resource_locator.md` —
  full standalone page. Sections: purpose + scheme, API table,
  known-kind taxonomy (with the `spaceship` example showing
  forward-compat), locality segments table, NATS subject
  derivation (mapping rules + lossiness caveat + round-trip
  parser), data-resource builders, related-links to topology /
  frames / payload_store / event_store.

- **Updated** `repos/noetl-wiki/noetl/core/runtime/topology.md`:
  - Worker-locator schema now reads
    `noetl://tenant/<t>/org/<o>[/region/<r>][/zone/<z>][/cluster/<c>][/node/<n>]/worker/<pool>`.
  - Added `region` / `zone` rows to the segment table.
  - Updated the `worker_locator()` + `parse_worker_locator()`
    examples to include the new fields.
  - Cross-link added to the new `Resource Locator` page.

- **Updated** `repos/noetl-wiki/Home.md`:
  - New row under `noetl/core/` for **Resource Locator**.
  - Existing **Runtime Topology** row description tightened to
    mention `region / zone / cluster / node`.

- **Updated** `repos/noetl-wiki/_Sidebar.md`:
  - Inserted `[Resource Locator](resource_locator)` just before
    `[Runtime Topology](topology)`.

- Wiki commit:
  `wiki(resource_locator,topology): URN extension — known-kind taxonomy, NATS subjects, data resources, region/zone`
  (`noetl.wiki@e7e4842`). Pushed to `origin/master`.

## Phase E — verify locally

- Pytest is the only required gate this round. Already green;
  see Phase C numbers (44 passed in the focused file scope, 144
  passed across the wider event_store / payload_store / replay
  sweep).

## Phase F — open PR and merge

- Branch `kadyapam/phase4-urn-extension` pushed.
- PR opened: **noetl#593** "feat(resource-locator): URN extension
  for data resources, locality, and NATS subjects" —
  https://github.com/noetl/noetl/pull/593
- Body lists the architectural context from the user's direction,
  exhaustive change list, URN reference, test plan, paired wiki
  commit pointer, and follow-up list for rounds 2 + 3.

**Merge step blocked: awaiting `merge phase 4 urn`.** No
`gh pr merge` run.

## Issues observed

- **Self-inflicted test bug caught fast.** Initial
  `test_to_nats_subject_does_not_emit_nats_forbidden_chars` tried
  to construct a locator with `or/g` as a segment — but
  `_normalize_segment` rejects `/` at parser time, so the test
  blew up before reaching `to_nats_subject()`. Reworded the test
  to use only characters that survive the segment-construction
  guard but still need collapse at NATS-subject time (`?`, space,
  `*`, `>`, `&`). 43→44 passed on the next run.
- The earlier pytest invocation was reported as "stuck" — it
  wasn't; the tool call was rejected at the harness level before
  it actually ran. Re-ran with `timeout 60` for explicit
  hard-stop semantics; ran in 0.45s.
- No pre-existing `CatalogResource` failure surfaced in this
  sweep because none of the test files involved import
  `noetl.server.api.catalog`. (The failure noted in round 5's
  result is still pre-existing on main; unrelated to this
  round's scope.)

## Manual escalation needed

To complete Phase F, the human (or a subsequent agent acting on
their go-ahead) must:

1. Confirm CI passes on noetl#593.
2. Say the wait phrase `merge phase 4 urn`.
3. Then the executor runs:

   ```
   gh pr merge 593 --admin --merge --delete-branch
   git -C repos/noetl fetch origin
   git -C repos/noetl checkout main && git -C repos/noetl pull origin main
   git -C repos/noetl-wiki pull origin master    # already at e7e4842
   git -C /Volumes/X10/projects/noetl/ai-meta add repos/noetl repos/noetl-wiki
   git -C /Volumes/X10/projects/noetl/ai-meta commit -m "chore(sync): bump noetl + noetl-wiki for phase4 URN extension"
   git -C /Volumes/X10/projects/noetl/ai-meta push origin main
   ```
4. Archive the handoff thread under `handoffs/archive/`.
5. Drop a `memory_add.sh` entry summarizing Phase 4 round 1.
