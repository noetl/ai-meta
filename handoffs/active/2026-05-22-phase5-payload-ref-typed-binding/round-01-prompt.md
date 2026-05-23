---
thread: 2026-05-22-phase5-payload-ref-typed-binding
round: 1
from: claude
to: claude
created: 2026-05-22T23:35:00Z
status: open
expects_result_at: round-01-result.md
---

# Phase 5 round 5: EventRecord.payload_ref typed binding

> **Predecessor:** Phase 5 round 4 completed in
> `handoffs/archive/2026-05-22-phase5-payload-store-azure/`
> (PR #591). Cloud-adapter rollout is complete (filesystem +
> S3 + GCS + Azure + SeaweedFS-via-S3).

This round closes out **Phase 5** by adding a typed binding on
`EventRecord.payload_ref` so callers can pass a
`PayloadReference` (the typed shape from
`noetl.core.payload_store`) directly to the event-store envelope.
The envelope serializes it to a canonical, JSON-column-compatible
dict with a discriminator so downstream consumers can recognize
payload-store-backed references without losing back-compat with
the existing TempStore-shaped dicts.

## Why this round, why this scope

Rounds 1–4 built the port + four adapters. Each adapter's
`store()` returns a `PayloadReference` — but the event store's
`payload_ref` field is still typed `Optional[dict[str, Any]]`,
so a caller that wants to write a payload-store-backed reference
has to hand-roll the dict shape. That's fragile and uninspectable.

This round adds the typed binding at the envelope-construction
boundary only. It does **not**:

- Wire any caller to actually produce `PayloadReference` instances
  (the storage tier's spill-to-payload-store path is a separate,
  larger piece of work that will benefit from this binding once
  it lands).
- Migrate any existing `payload_ref` writes (the existing
  TempStore-shaped dicts continue to round-trip unchanged).
- Change the postgres `payload_ref` JSON column type or shape.
- Touch the `TempStoreReplayPayloadResolver` resolution path
  (resolving cloud URIs through the PayloadStore is a future
  round once a caller actually writes one).

Scope discipline keeps the round small enough to merge cleanly
and lets the next phase (Phase 4 — URN extension / KEDA / NATS
supercluster) start fresh.

## What this round delivers

1. `EventRecord.payload_ref` typing widened to
   `Optional[Union[PayloadReference, dict[str, Any]]]` (or the
   equivalent `Optional[Any]` with runtime validation — Phase A
   picks the cleanest shape given `@dataclass(frozen=True)`
   constraints).
2. New module-level helper `payload_ref_to_dict(value) -> Optional[dict[str, Any]]`
   in `noetl/core/event_store/ports.py` that normalizes:
   - `None` → `None`
   - `PayloadReference` → canonical dict with `kind: "payload_store"`
     discriminator + every field (`sha256`, `byte_length`,
     `content_type`, `uri`, `metadata`).
   - `dict` → returned unchanged.
   - Anything else → `TypeError` with a clear message.
3. `EventRecord.envelope()` applies `payload_ref_to_dict` to
   `self.payload_ref` so the envelope dict always contains a
   serializable shape.
4. `replay_payload_ref_locator` in
   `noetl/server/api/replay/payload_resolver.py` recognizes the
   `kind: "payload_store"` discriminator and prefers `uri` as the
   locator. This is mostly a no-op (the existing
   `("ref", "uri", "locator")` lookup already extracts `uri`),
   but a typed discriminator makes the recognition explicit +
   testable + an obvious extension point for a future
   PayloadStore-aware resolver.
5. Unit tests in
   `tests/core/event_store/test_payload_ref_binding.py`:
   - Envelope construction with a `PayloadReference` →
     canonical dict shape with `kind: "payload_store"`.
   - Envelope construction with a raw dict → round-trips
     unchanged.
   - Envelope construction with `None` → still emits
     `payload_ref: None`.
   - `payload_ref_to_dict` rejects non-dict / non-PayloadReference
     inputs with `TypeError`.
   - Checksum stability: envelopes built from
     `PayloadReference` and from its `payload_ref_to_dict`
     output produce identical `envelope_checksum`s.
   - `replay_payload_ref_locator` returns `uri` for a
     `kind: "payload_store"` dict.
   - `replay_payload_ref_locator` returns the existing
     `ref`/`uri`/`locator` keys for legacy dict shapes
     (regression guard).
6. Wiki page updates:
   - Extend `repos/noetl-wiki/noetl/core/payload_store.md` with
     a new `## EventRecord.payload_ref binding` section near the
     bottom (before `## Configuration`). Cross-link to the
     event_store page.
   - Extend `repos/noetl-wiki/noetl/core/event_store.md` (or
     whichever file the event-store envelope is documented in)
     with a `### payload_ref typed binding` subsection that
     covers the new `PayloadReference` accept path + canonical
     dict shape. Phase A verifies the right filename.

## Background

### Verified existing surface

- `noetl/core/event_store/ports.py` —
  `EventRecord.payload_ref: Optional[dict[str, Any]] = None`,
  used by `envelope()` to build a JSON-column-compatible dict
  that flows into the postgres `payload_ref` column via
  `noetl/core/event_store/postgres.py`.
- `noetl/core/payload_store/ports.py` —
  `PayloadReference` dataclass with `sha256`, `byte_length`,
  `content_type`, `uri`, `metadata`.
- `noetl/server/api/replay/payload_resolver.py` —
  `replay_payload_ref_locator(reference)` already pulls `uri`
  out of a mapping (along with `ref`/`locator`/nested
  `rows_ref`). Round 5 adds explicit recognition of the
  `kind: "payload_store"` discriminator so the new shape is
  testable + visible.
- `noetl/server/api/frames/endpoint.py` and
  `noetl/server/api/replay/service.py` are existing callers
  that consume `payload_ref` as a generic dict. They keep
  working unchanged because the typed binding only adds the
  `PayloadReference → dict` accept path; existing dict shapes
  flow through untouched.

### Why no consumer rewiring

The replay resolver path (`TempStoreReplayPayloadResolver`)
currently calls `self.store.resolve(<locator>)` against the
TempStore. PayloadStore-backed URIs (`s3://`, `gs://`,
`azure://`) wouldn't resolve through TempStore today. Wiring
that path is a meaty change of its own (needs a router that
sees the `kind` and routes to either TempStore or a registered
PayloadStore) and would muddy this round's scope. Round 5 is
purely the typed envelope binding; the resolver-routing work
gets its own future round once a caller actually writes a
payload-store-backed reference.

### Discriminator design

Add a `kind` key to the canonical dict so the consumer can
recognize the source unambiguously without inspecting field
names:

- `kind: "payload_store"` — the canonical PayloadReference shape.
- Absence of `kind` (or any non-`payload_store` value) — legacy
  TempStore / ResultStore shape; treated as it is today.

This keeps the contract trivially forward-compatible: future
adapters (e.g. URN-shaped references in Phase 4) can pick their
own `kind` values without colliding.

## Phases

### Phase A — design + drift check (no remote writes)

1. Re-verify `event_store/ports.py`, `payload_store/ports.py`,
   `payload_resolver.py` on `origin/main` since round 4. Flag
   any drift.
2. Confirm the event-store wiki page name.
   `noetl/core/event_store.md` is the canonical path per the
   wiki structure.
3. Decide on the typing approach for the `@dataclass(frozen=True)`
   field. Two options:
   - **Option A:** Widen to `Optional[Any]`. Simpler; loses some
     type signal. Validation enforced at envelope-construction
     boundary via `payload_ref_to_dict`.
   - **Option B:** Widen to `Optional[Union[PayloadReference, dict[str, Any]]]`.
     Stronger signal. Costs an import of `PayloadReference` into
     `event_store/ports.py` — accept the dep direction:
     event_store depends on payload_store's port. This is fine
     because `payload_store/ports.py` is a leaf module (no
     event_store import), so no cycle is created.
   - **Recommendation: Option B.** Make the dependency explicit;
     the round's whole point is that the event store knows about
     PayloadReference. Phase A confirms no import cycle.

### Phase B — implementation

4. **Envelope binding** — `noetl/core/event_store/ports.py`:
   - Add `from noetl.core.payload_store.ports import PayloadReference`
     at the top (verify no cycle in Phase A).
   - Add module-level helper:
     ```python
     def payload_ref_to_dict(
         value: Optional[Union[PayloadReference, dict[str, Any]]],
     ) -> Optional[dict[str, Any]]:
         ...
     ```
     Returns:
     - `None` for `None`.
     - For a `PayloadReference`: a dict with key `"kind"` set to
       `"payload_store"` followed by `sha256`, `byte_length`,
       `content_type`, `uri`, `metadata` (in that order — the
       canonical_event_checksum already sorts keys, but ordered
       construction is friendlier for debugging).
     - For a `dict`: the dict itself (no copy needed — the
       envelope is consumed as JSON).
     - For anything else: raise `TypeError` with a message
       describing the accepted shapes.
   - Update `EventRecord.payload_ref` typing to
     `Optional[Union[PayloadReference, dict[str, Any]]]`.
   - Update `envelope()` to call
     `payload_ref_to_dict(self.payload_ref)` instead of using
     `self.payload_ref` directly.

5. **Locator discriminator** —
   `noetl/server/api/replay/payload_resolver.py`:
   - In `replay_payload_ref_locator`, after the
     `isinstance(reference, Mapping)` branch, add an explicit
     check: if `reference.get("kind") == "payload_store"`, prefer
     the `uri` field. (The current implementation already
     extracts `uri` first in the `("ref", "uri", "locator")`
     loop, but the explicit kind-check provides a stable
     extension point and a documentation anchor.)
   - Keep the existing legacy-shape lookup intact for
     back-compat.

### Phase C — tests

6. New file `tests/core/event_store/test_payload_ref_binding.py`:
   - `test_envelope_serializes_payload_reference_to_canonical_dict`
     — construct an `EventRecord` with a `PayloadReference`,
     call `envelope(stream_version=1)`, assert the
     `payload_ref` key contains
     `{"kind": "payload_store", "sha256": ..., "byte_length": ...,
     "content_type": ..., "uri": ..., "metadata": {...}}`.
   - `test_envelope_passes_through_legacy_dict_unchanged` —
     construct an `EventRecord` with a raw dict (e.g.
     `{"kind": "result_ref", "ref": "/tmp/foo"}`), assert the
     envelope's `payload_ref` is the same dict.
   - `test_envelope_handles_none_payload_ref` — assert the
     envelope's `payload_ref` is `None`.
   - `test_payload_ref_to_dict_rejects_invalid_input` — pass a
     `str`, an `int`, and a `list`; expect `TypeError`.
   - `test_checksum_matches_between_payload_reference_and_dict_form`
     — build two `EventRecord`s with identical fields except one
     has a `PayloadReference` and the other has the
     `payload_ref_to_dict(...)` output. Assert the
     `envelope_checksum` values are equal (the helper must be
     idempotent / canonical).
   - `test_payload_ref_metadata_preserved_in_envelope` —
     `PayloadReference` with non-empty `metadata`; envelope
     dict's metadata sub-dict matches.

7. New file
   `tests/server/api/replay/test_payload_ref_locator_kind.py`
   (or extend an existing locator test if one exists — Phase A
   checks):
   - `test_locator_extracts_uri_for_payload_store_kind` —
     `{"kind": "payload_store", "uri": "gs://bucket/key"}` →
     `"gs://bucket/key"`.
   - `test_locator_returns_uri_when_kind_unset_legacy` —
     `{"uri": "/tmp/foo"}` → `"/tmp/foo"`.
   - `test_locator_returns_none_for_empty_dict` — `{}` → `None`.
   - `test_locator_returns_string_for_bare_string_locator` —
     `"some-ref"` → `"some-ref"` (regression guard).

8. Run:
   ```
   .venv/bin/python -m pytest tests/core/event_store/ -q
   .venv/bin/python -m pytest tests/server/api/replay/ -q
   .venv/bin/python -m pytest tests/core/event_store/
         tests/core/payload_store/
         tests/core/test_replay_state_projector.py
         tests/server/api/replay/ -q
   ```
   All green.

### Phase D — wiki update

9. Update `repos/noetl-wiki/noetl/core/payload_store.md`:
   - Add `## EventRecord.payload_ref binding` section near the
     bottom (before `## Configuration` if it exists in that
     position, otherwise pick the most logical anchor). Cover:
     - Why the binding exists (callers writing
       PayloadStore-backed events).
     - Accept shapes (`PayloadReference` instance OR dict OR
       None).
     - Canonical dict shape with `kind: "payload_store"`
       discriminator.
     - Forward-compat: legacy dict shapes flow through
       untouched.
   - Status section: phase line reads "Rounds 1–5 complete
     (port + filesystem + S3 + GCS + Azure +
     `EventRecord.payload_ref` typed binding). **Phase 5
     closed.**" Drop the "not yet migrated" line about the
     storage tier — instead note that the storage tier's
     actual spill-to-payload-store wiring remains future work
     (separate from Phase 5).

10. Update `repos/noetl-wiki/noetl/core/event_store.md`:
    - Add a `### payload_ref typed binding` subsection under
      whichever H2 documents the envelope shape (Phase A
      identifies). Cover the same accept-shape contract +
      cross-link to the payload_store page.

11. Commit + push wiki.

### Phase E — verify locally

12. Pytest is the only required gate. Already covered by Phase C.

### Phase F — open PR and merge

> ***Run only after explicit human go-ahead. Wait phrase: `merge phase 5 binding`.***

13. Push branch `kadyapam/phase5-payload-ref-typed-binding`,
    open noetl PR titled
    `feat(event-store): bind payload_ref to PayloadReference`.
14. Wait for CI / human review.
15. Merge with `--admin --merge --delete-branch`.
16. Bump ai-meta pointers (noetl + noetl-wiki).
17. Archive handoff + add memory entry summarizing Phase 5
    completion.

## FINAL REPORT

Body sections — one H2 per Phase A–F, plus `## Issues observed`
and `## Manual escalation needed`.

## Hard rules

- Never push to `origin/main` on any repo unless this prompt
  says so. Phase F is the only step that pushes, gated by
  `merge phase 5 binding`.
- Never force-push.
- Never merge PRs yourself before the gate phrase.
- Respect `agents/rules/wiki-maintenance.md` — Phase D wiki
  edit ships paired with the code change.
- Do not store secrets in any file under ai-meta.
- If a step's preconditions aren't met, stop and write the
  report with `status: blocked`.
- **No storage-tier rewiring in this round.** The PayloadStore
  spill path stays as future work.
- **No postgres schema change in this round.** The
  `payload_ref` JSON column shape is unchanged; only the
  Python-side accept path is widened.
- **No resolver-routing change in this round.** The
  `TempStoreReplayPayloadResolver` keeps its current behavior;
  payload-store-backed refs aren't yet resolved through their
  PayloadStore adapters.
