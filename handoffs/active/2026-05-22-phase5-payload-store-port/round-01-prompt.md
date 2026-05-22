---
thread: 2026-05-22-phase5-payload-store-port
round: 1
from: claude
to: claude
created: 2026-05-22T21:34:25Z
status: open
expects_result_at: round-01-result.md
---

# Phase 5 round 1: payload-store port + filesystem reference adapter

> **Predecessor:** Phase 3 completed in
> `handoffs/archive/2026-05-22-phase3-ipc-observability/`
> (noetl v2.92.0). v2 spec status: 0/1/2/3/6 done; 4/5 outstanding.

Phase 5 of the v2 distributed-runtime spec asks for the **third
port-and-adapter family** in NoETL, parallel to:

- `noetl.core.event_store` — `EventStore` Protocol + Postgres
  reference (done).
- `noetl.core.projection_store` — `ProjectionStore` Protocol +
  Postgres reference (done).

This round establishes the **payload store** port and ships a
**filesystem reference adapter**. Cloud adapters (S3, GCS, Azure
Blob, SeaweedFS) land in subsequent rounds.

## Why filesystem (and not Postgres) for the reference

The two existing ports use Postgres references because their data
fits PG (relational events, JSONB projections). Payloads are
**blob-shaped** — content-addressed bytes — and PG is wrong as the
canonical implementation. The v2 spec calls out S3 / GCS / Azure
Blob / SeaweedFS / **local filesystem** as the backend set. The
local filesystem reference is:

- Testable without any cloud / Postgres / NATS.
- The canonical single-node-edge deployment shape.
- The cleanest target for a content-addressed protocol.

## What this round delivers

1. New package `noetl/core/payload_store/`:
   - `ports.py` — `PayloadStore` Protocol, `PayloadReference`
     dataclass, `PayloadNotFound` exception.
   - `filesystem.py` — `FilesystemPayloadStore` reference adapter
     with content-addressed storage (SHA-256), atomic writes,
     directory sharding (`AB/CDEF...`), and an optional
     metadata sidecar.
   - `__init__.py` — re-exports.
2. New test file `tests/core/payload_store/test_filesystem.py`.
3. New wiki page `noetl/core/payload_store.md` mirroring the
   structure of `noetl/core/event_store.md` and
   `noetl/core/projection_store.md`.

## Out of scope for this round

- **No migration of existing callers.** `TempStore` and the
  storage tier keep working unchanged. The port establishes the
  contract; future rounds add direct adapters and (selectively)
  migrate callers.
- **No cloud adapters.** S3 / GCS / Azure Blob / SeaweedFS land
  as separate rounds.
- **No event-envelope integration.** Wiring `EventRecord.payload_ref`
  to consume a `PayloadStore` is a follow-up.

## Background

### Verified existing surface

- [`noetl/core/event_store/ports.py`](https://github.com/noetl/noetl/blob/main/noetl/core/event_store/ports.py)
  — template port shape: `Protocol` + `@dataclass(frozen=True)`
  record + module-level helpers + error class.
- [`noetl/core/projection_store/ports.py`](https://github.com/noetl/noetl/blob/main/noetl/core/projection_store/ports.py)
  — same pattern.
- [`noetl/core/storage/`](https://github.com/noetl/noetl/tree/main/noetl/core/storage)
  — the existing tiered result store. **Stays unchanged.**
  Wiki page exists at [Storage](https://github.com/noetl/noetl/wiki/storage).

## Phases

### Phase A — design + drift check (no remote writes)

1. Re-read this prompt against `origin/main`. Flag drift in the
   two existing port files.
2. Decide the canonical `PayloadReference` field set.
   Recommendation:
   ```python
   @dataclass(frozen=True)
   class PayloadReference:
       sha256: str                    # content hash (lowercase hex)
       byte_length: int               # bytes stored
       content_type: str              # MIME, default application/octet-stream
       uri: Optional[str]             # backend-specific (filesystem absolute path / s3:// / gs:// …)
       metadata: dict[str, str]       # opaque key/value pairs (small)
   ```
3. Decide whether `store` returns a `PayloadReference` directly or
   wraps with a stored-version envelope. Recommendation: return
   `PayloadReference` directly — keeps the surface symmetric with
   `EventStore.append` returning the new version.
4. Decide directory sharding for the filesystem adapter.
   Recommendation: 2-level sharding `<root>/<sha[0:2]>/<sha[2:4]>/<sha>`
   so any single dir stays under 10k entries even at billions of
   blobs. Cheap, well-known pattern.
5. Decide write semantics. Recommendation: atomic via
   `tempfile.NamedTemporaryFile(dir=...) + os.replace` so partial
   writes never appear as valid blobs.

### Phase B — implementation

6. **Port** — `noetl/core/payload_store/ports.py`:
   - Mirror the style of `event_store/ports.py` (Protocol +
     frozen dataclass + module-level error class).
   - Define:
     - `class PayloadNotFound(KeyError): ...`
     - `@dataclass(frozen=True) class PayloadReference`
     - `class PayloadStore(Protocol):` with async methods:
       - `async def store(self, payload: bytes, *,
            content_type: str = "application/octet-stream",
            metadata: Optional[dict[str, str]] = None,
         ) -> PayloadReference`
       - `async def fetch(self, reference: PayloadReference) -> bytes`
       - `async def exists(self, reference: PayloadReference) -> bool`
       - `async def delete(self, reference: PayloadReference) -> bool`
   - Add a small module-level `content_hash(payload: bytes) -> str`
     helper that returns the lowercase hex SHA-256.

7. **Filesystem adapter** — `noetl/core/payload_store/filesystem.py`:
   - `class FilesystemPayloadStore` constructor takes a root
     directory (`pathlib.Path | str`), an optional sharding
     depth (default 2), and a default content type.
   - `store(payload, ...)` — compute SHA-256, build target path
     via sharded layout, skip write if blob already exists
     (content-addressing dedup), write atomically via
     `tempfile.NamedTemporaryFile(delete=False, dir=parent) +
     os.replace`, optionally write a `<sha>.meta.json` sidecar
     with `{content_type, metadata, byte_length, created_at}`.
   - `fetch(ref)` — read bytes from the sharded path; raise
     `PayloadNotFound` if missing.
   - `exists(ref)` — return `True` iff file exists at the
     sharded path.
   - `delete(ref)` — remove the file (and sidecar if present);
     return `True` on success, `False` if already absent.
   - Operations are async (using `asyncio.to_thread` for the
     blocking filesystem calls — async I/O on local FS gains
     nothing real, but keeps the Protocol signature uniform).

8. **Package init** — `noetl/core/payload_store/__init__.py`:
   - Re-export `PayloadStore`, `PayloadReference`, `PayloadNotFound`,
     `content_hash`, `FilesystemPayloadStore`.
   - Provide a docstring that names the port + reference adapter.

### Phase C — tests

9. New file `tests/core/payload_store/test_filesystem.py`
   (create `tests/core/payload_store/__init__.py` if needed):
   - `test_store_and_fetch_round_trip` — store small bytes, fetch
     them back, assert byte equality and `len == byte_length`.
   - `test_content_addressing_is_deterministic` — same bytes
     stored twice → same `PayloadReference.sha256`, only one file
     on disk.
   - `test_store_skips_write_when_blob_exists` — store the same
     payload twice; second call doesn't rewrite (test by checking
     mtime stays put).
   - `test_atomic_write_temp_file_cleanup` — sanity check that no
     `tmp*` files remain in the sharded directory after a
     successful store.
   - `test_fetch_missing_raises_payload_not_found` — construct a
     reference for unknown sha; assert `PayloadNotFound`.
   - `test_exists_reflects_state` — exists False → store → exists
     True → delete → exists False.
   - `test_delete_returns_false_when_missing` — delete on unknown
     ref returns False, doesn't raise.
   - `test_metadata_sidecar_round_trip` — store with non-empty
     metadata, assert sidecar is written and parseable JSON with
     the expected fields.
   - `test_content_type_default` — default content_type is
     `application/octet-stream`.

10. Run the full focused suite:
    `pytest tests/core/payload_store tests/core/test_projector_metrics.py
            tests/core/test_replay_state_projector.py
            tests/unit/dsl/engine/test_fanout_reduce_planner.py -q`
    — all green.

### Phase D — wiki update

11. New wiki page `noetl/core/payload_store.md` in
    `repos/noetl-wiki/`, mirroring the structure of
    [`noetl/core/event_store.md`](https://github.com/noetl/noetl/wiki/event_store):
    - Status (port-and-adapter shape, where it sits relative to
      `event_store` / `projection_store` / `storage`).
    - Interface contract — Protocol signature.
    - `PayloadReference` field table.
    - Filesystem adapter behavior: content-addressing, sharded
      layout, atomic write, dedup, sidecar.
    - Configuration / env vars (root path default).
    - Where this fits diagram (port + reference, contrast with
      `storage` tier).
    - Related links — event_store, projection_store, storage,
      runtime spec.

12. Add the new page to:
    - `Home.md` — under Core, alongside the other two store pages.
    - `_Sidebar.md` — same group.

13. Push the wiki commit.

### Phase E — verify locally

14. Pytest already covers the surface end-to-end (filesystem is
    the entire backend — no kind / Postgres / NATS needed).
    No local-kind step in this round.

### Phase F — open PR and merge

> ***Run only after explicit human go-ahead. Wait phrase: `merge phase 5`.***

15. Push branch `kadyapam/phase5-payload-store-port`, open noetl
    PR titled `feat(payload-store): add port + filesystem reference
    adapter`. Body references this handoff + the new wiki page.
16. Wait for CI / human review.
17. Merge with `--admin --merge --delete-branch`.
18. Bump ai-meta pointers (noetl + noetl-wiki) in coordinated
    chore(sync) commits.

## FINAL REPORT

Body sections — one H2 per Phase A–F, plus `## Issues observed`
and `## Manual escalation needed`.

## Hard rules

- Never push to `origin/main` on any repo unless this prompt says
  so. Phase F is the only step that pushes, gated by `merge phase 5`.
- Never force-push.
- Never merge PRs yourself before the gate phrase.
- Respect `agents/rules/wiki-maintenance.md` — the Phase D wiki
  page ships paired with the code change.
- Do not store secrets in any file under ai-meta.
- If a step's preconditions aren't met, stop and write the report
  with `status: blocked`.
- **No migration of existing callers, no cloud adapters, no
  event-envelope integration in this round.** Subsequent
  payload-store rounds add those.
