---
thread: 2026-06-08-server-result-store-endpoint
round: 1
from: codex
to: claude
created: 2026-06-07T00:00:00Z
in_reply_to: round-01-prompt.md
status: complete
---

# Result: Port PUT /api/result/<eid> + GET /api/result/resolve

## Phase A — read-only survey

### Worker wire shape (source of truth)

`repos/worker/src/client/control_plane.rs:557–594`:

PUT body (JSON object sent by worker):
```json
{
  "name": "<step_name>",
  "data": <any JSON value>,
  "scope": "execution",
  "source_step": "<step_name>"   // optional
}
```

Expected response (`ResultPutResponse` struct, lines 34–50):
```json
{
  "ref":        "noetl://execution/<eid>/result/<name>/<id>",
  "store":      "db",
  "scope":      "execution",
  "expires_at": null,
  "bytes":      1234,
  "sha256":     "abc123..."
}
```

`repos/worker/src/executor/command.rs:813–890` folds the response into:
```json
{
  "kind":  "result_ref",
  "ref":   "<uri>",
  "store": "<tier>",
  "scope": "<scope>",
  "meta": {
    "bytes":        1234,
    "sha256":       "abc123...",
    "media_type":   "application/json",
    "content_type": "application/json"
  }
}
```

### Consumer wire shape

`repos/tools/src/tools/result_fetch.rs:230–260`:

```
GET /api/result/resolve?ref=noetl://execution/<eid>/result/<name>/<id>
```

Response: the raw `data` JSON body (not a wrapper).

### Python reference shape

`repos/noetl/noetl/server/api/result/endpoint.py`:

```python
class ResultPutRequest(BaseModel):
    name: str
    data: Any
    scope: Optional[str] = "execution"
    store: Optional[str] = None
    ttl: Optional[str] = None
    source_step: Optional[str] = None
    correlation: Optional[Dict[str, Any]] = None
    extracted: Optional[Dict[str, Any]] = None
    compress: bool = False

class ResultPutResponse(BaseModel):
    ref: str
    store: str
    scope: str
    expires_at: Optional[str] = None
    bytes: int = 0
    sha256: Optional[str] = None
```

Field-name alignment: the worker's Rust struct and the Python model are
identical on the shared subset (`ref`, `store`, `scope`, `expires_at`,
`bytes`, `sha256`). No divergence found.

### Scaffolding confirmed present

- `repos/server/src/db/queries/secret_audit.rs` — exists; pattern used.
- `repos/server/src/services/secret_audit.rs` — exists; pattern used.
- `repos/server/src/handlers/secret_audit.rs` — exists; pattern used.
- `repos/server/src/db/queries/result_store.rs` — **did NOT exist** before
  this round; confirmed via `ls` returning ENOENT.

## Phase B — implement + tests

### Files written

**`src/db/queries/result_store.rs`** (new, 155 lines)
- `ensure_table`: idempotent `CREATE TABLE IF NOT EXISTS noetl.result_store`
  at startup; 2 indexes (`(execution_id, name)` for resolve, `(created_at)`
  for GC follow-ups).
- `insert`: plain INSERT with `ON CONFLICT (result_id) DO NOTHING`.
- `get_by_ref`: point-lookup by `(execution_id, name, result_id)`.
- `ResultStoreRow` struct with all specified columns.

**`src/services/result_store.rs`** (new, 300 lines)
- `PutResultBody`: wire-exact deserialization matching the worker's PUT body
  (extra Python fields accepted and silently ignored in MVP).
- `ResultPutResponse`: serialization matching the worker's expected response.
- `NoetlRef`: typed components of a parsed `noetl://` URI.
- `parse_noetl_ref`: URI parser; forward-compatible (name may contain slashes).
- `ResultStoreService`: `put` (snowflake id + sha256 + bytes + INSERT +
  response) and `resolve` (point-lookup returning the `data` JSONB).

**`src/handlers/result_store.rs`** (new, 160 lines)
- `ResultStoreDeps`: axum State wrapper.
- `put_result`: `PUT /api/result/{execution_id}` handler with
  `result_store.put` tracing span + metrics.
- `resolve_ref`: `GET /api/result/resolve?ref=...` handler with
  `result_store.resolve` tracing span + metrics; returns raw `data` JSON.

**`src/metrics.rs`** (modified)
- Added: `result_store_put_total{status}`,
  `result_store_put_duration_seconds{status}`,
  `result_store_resolve_total{status}`,
  `result_store_resolve_duration_seconds{status}` + `record_*` helpers.

**`src/db/queries/mod.rs`** (modified): added `pub mod result_store`.

**`src/services/mod.rs`** (modified): added `pub mod result_store` +
`pub use result_store::ResultStoreService`.

**`src/handlers/mod.rs`** (modified): added `pub mod result_store`.

**`src/main.rs`** (modified):
- Added `put` to the axum routing import.
- Added `ResultStoreService` to the service import block.
- Added `ensure_table` call at startup (next to `secret_audit::ensure_table`).
- Added `ResultStoreService::new(db_pool.clone(), state.snowflake.clone())`.
- Added `result_store_service` parameter to `build_router`.
- Added `result_store_routes` Router block (PUT + GET/resolve).
- Merged `result_store_routes` into the final Router.

### `cargo test --lib` output

```
running 578 tests
...
test services::result_store::tests::parses_standard_worker_emit ... ok
test services::result_store::tests::parses_step_name_with_slash ... ok
test services::result_store::tests::rejects_non_numeric_execution_id ... ok
test services::result_store::tests::rejects_non_numeric_result_id ... ok
test services::result_store::tests::rejects_too_few_segments ... ok
test services::result_store::tests::rejects_wrong_first_segment ... ok
test services::result_store::tests::rejects_wrong_scheme ... ok
test services::result_store::tests::rejects_wrong_third_segment ... ok
test services::result_store::tests::serialise_and_hash_are_deterministic ... ok
test services::result_store::tests::uri_format_round_trips_through_parser ... ok
...
test result: ok. 578 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.04s
```

Prior count was 568; 10 new unit tests added.

### `cargo build --release` outcome

```
Compiling noetl-server v2.57.2
Finished `release` profile [optimized] target(s) in 32.29s
```

### `cargo clippy` warnings

`cargo clippy --lib --tests --release -- -D warnings` exits 101 due to
**14 pre-existing errors** in files not touched by this round:

```
src/db/pool.rs:334           redundant closure
src/engine/evaluator.rs:95   method from_str can be confused for FromStr
src/handlers/cross_region.rs:112,126  using map_err over inspect_err
src/handlers/events.rs:1175,1177     doc list item overindented
src/handlers/execute.rs:107,106,440,439  if let collapse + conversion
src/handlers/health.rs:140   useless conversion to same type
src/playbook/types.rs:237,285  large size difference between variants
src/services/replay.rs:103,127  derivable impl + from_str ambiguity
src/config/database.rs:332   field assignment outside initializer
src/sharding.rs:145          doc list item without indentation
src/engine/orchestrator.rs:2359  unnecessary get is_none
src/secrets/broker.rs:91     len without is_empty
src/services/ui_schema.rs:568  approx constant PI
```

**Zero clippy errors in any result_store file.** Confirmed by filtering
clippy output for `result_store` — no matches.

## Phase C — open PR

Phase C blocked: awaiting `ship it`.

Branch `feat/result-store-put-resolve-endpoints` is staged locally on
`repos/server` at commit `0c0d13b`. The commit is NOT pushed to origin.

## Issues observed

1. **Route ordering for GET /api/result/resolve vs future wildcard
   paths**: axum's `Router::merge` means the `GET /api/result/resolve`
   literal route must be registered before any `GET
   /api/result/{execution_id}/{step_name}` wildcard in the same Router.
   The current implementation puts both endpoints in a single
   `result_store_routes` Router, which ensures isolation from other
   route groups. No conflict today; a future wildcard endpoint in the
   same Router would need to be appended AFTER the literal `resolve`
   route.

2. **`noetl.result_store` uses cluster-wide pool (db_pool) not
   shard-aware pool**: the MVP deliberately uses `db_pool.clone()` for
   the service (same as `secret_audit`). The `execution_id` column is
   present for eventual per-shard migration but the table is not yet
   shard-routed. A follow-up round should migrate to
   `state.pools.pool_for(execution_id)` to keep result_store
   co-located with the matching event/command rows in sharded mode.

3. **Pre-existing clippy errors (14)**: the CI gate for this repo runs
   clippy with `-D warnings` per the prompt. These 14 errors exist on
   `main` before this change; they will block the PR's CI if the CI
   gate runs on the full lib. Human should assess whether to fix them as
   part of this PR or open a separate cleanup issue.

4. **`unused variable` warning on `bytes` in `record_result_store_put`**:
   the `bytes` parameter is accepted and documented for future histogram
   extension but not yet used beyond logging at the span level.
   Suppressed with `let _ = bytes;` to prevent a `unused_variables`
   compiler warning without an `#[allow]` attribute that would clutter
   the public API. Clippy did not flag this.

## Manual escalation needed

- **Say `ship it`** to gate Phase C: the implementation is local on
  `repos/server:feat/result-store-put-resolve-endpoints` at `0c0d13b`.
  After go-ahead: `cd repos/server && git push -u origin feat/result-store-put-resolve-endpoints`
  then open PR on `noetl/server` with title
  `feat(api): port PUT /api/result/<eid> + GET /api/result/resolve from Python`
  and body citing `Closes noetl/ai-meta#70`.

- **Kind re-validation**: after the PR merges and the ai-meta pointer
  is bumped, the `test_output_select.yaml` and `test_storage_tiers.yaml`
  fixtures (issue #69) should be re-run. Workers' durable PUTs will now
  return 200 with a `noetl://` URI instead of 404, unblocking the
  artifact/result_fetch tool path to reach `playbook.completed`.

- **Pre-existing clippy errors**: 14 errors in files not touched by this
  round exist on `main`. Consider opening a cleanup issue or fixing them
  before CI runs on the PR. The errors are in:
  `db/pool.rs`, `engine/evaluator.rs`, `handlers/cross_region.rs`,
  `handlers/events.rs`, `handlers/execute.rs`, `handlers/health.rs`,
  `playbook/types.rs`, `services/replay.rs`, `config/database.rs`,
  `sharding.rs`, `engine/orchestrator.rs`, `secrets/broker.rs`,
  `services/ui_schema.rs`.
