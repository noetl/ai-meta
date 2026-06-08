---
thread: 2026-06-08-server-result-store-endpoint
round: 1
from: claude
to: codex
created: 2026-06-08T04:25:00Z
status: open
expects_result_at: round-01-result.md
---

# Port `PUT /api/result/<eid>` + `GET /api/result/resolve` to noetl-server

Tracks [noetl/ai-meta#70](https://github.com/noetl/ai-meta/issues/70).
Surfaced today during the [noetl/ai-meta#69](https://github.com/noetl/ai-meta/issues/69) kind re-val:
the Rust noetl-server doesn't expose the result-store write endpoint
that the worker has been calling for the entire Phase D+E+F
lifetime (R-2.2 PR-B at `repos/worker/src/client/control_plane.rs:557`).
Workers' durable PUTs return HTTP 404 and they fall back to the
degraded shm-only branch, so the consuming `artifact` /
`result_fetch` tools can't find a `noetl://` URI to fetch.

Your job is the **MVP port** that closes the worker contract +
unblocks kind-val of the artifact-using fixtures
(`test_output_select.yaml`, `test_storage_tiers.yaml`).

## Background

- Operate in `repos/server` (the Rust noetl-server submodule).
- Reference impl: `repos/noetl/noetl/server/api/result/`
  (`endpoint.py` 398 LoC + `flight_server.py` 562 LoC) — Python
  source-of-truth. Read it before touching anything.
- Worker wire contract (the thing you must satisfy):
  - `repos/worker/src/client/control_plane.rs:557-594` (`put_result`)
    — issues `PUT {server}/api/result/{execution_id}` body
    `{name, data, scope, source_step?}` → expects
    `ResultPutResponse { ref, store, scope, bytes, sha256, expires_at? }`.
  - `ref` shape: `noetl://execution/<eid>/result/<name>/<id>`.
  - Worker `build_call_done_result` at
    `repos/worker/src/executor/command.rs:813-890` shows how the
    response gets folded into the `reference: { kind: "result_ref", ref, store, scope, meta: { bytes, sha256, media_type, content_type } }`
    block.
- Consumer wire contract:
  - `repos/tools/src/tools/result_fetch.rs:230` — HTTP fallback
    `GET /api/result/resolve?ref=<uri>` returns the stored payload.
  - The Arrow Flight gRPC fast path is **out of scope** for this
    round (the worker has the HTTP fallback baked in).
- Server scaffolding to mirror:
  - `repos/server/src/db/queries/secret_audit.rs` — closest existing
    pattern (server-owned table + INSERT/SELECT helpers; created via
    `CREATE TABLE IF NOT EXISTS` at startup, see #61 Phase 7b.2).
  - `repos/server/src/services/keychain.rs` — service-layer pattern
    you can copy for `result_store.rs`.
  - `repos/server/src/handlers/keychain.rs` — handler pattern
    (axum::extract::State, error mapping, structured logging).
  - `repos/server/src/main.rs` lines ~205-260 — route registration
    (see `executions_routes`, `replay_routes`).
  - `repos/server/src/db/queries/event.rs` — snowflake id generation
    pattern (used for `event_id`, same machinery can mint
    `result_id`).
- The previous session ALREADY did all the #69-side work, so the
  worker's expectation of this endpoint is fully wired and tested.
  This is purely a server-side write-channel addition.

## MVP scope

- New Postgres table `noetl.result_store`. Columns:
  - `result_id BIGINT PRIMARY KEY` (app-side snowflake; same pattern
    as `event_id` / `command_id` per
    `agents/rules/observability.md` Principle 3).
  - `execution_id BIGINT NOT NULL`.
  - `name TEXT NOT NULL` — the step / artifact name the worker
    sends (`name` field in the PUT body).
  - `scope TEXT NOT NULL` — `"execution"` is the only value the
    worker sends today; accept any short string.
  - `source_step TEXT NULLABLE` — optional, from PUT body.
  - `data JSONB NOT NULL` — the payload as-is.
  - `bytes BIGINT NOT NULL` — `data` serialised size.
  - `sha256 TEXT NOT NULL` — sha256 of the serialised JSON.
  - `media_type TEXT NOT NULL` (default `"application/json"`).
  - `created_at TIMESTAMPTZ NOT NULL DEFAULT now()`.
  - `expires_at TIMESTAMPTZ NULLABLE` — leave NULL for MVP
    (no expiry).
  - Indexes: `(execution_id, name)` for resolve, `(created_at)` for
    GC follow-ups.
- Provision via `CREATE TABLE IF NOT EXISTS` at server startup —
  identical pattern to `noetl.secret_audit` from #61 Phase 7b.2.
  Do NOT create a sqlx migration file; the project's pattern is
  startup-time idempotent DDL.
- New `src/db/queries/result_store.rs`:
  - `pub async fn insert(pool, ResultStoreRow) -> Result<()>` —
    plain INSERT.
  - `pub async fn get_by_ref(pool, eid, name, result_id) -> Result<Option<ResultStoreRow>>`
    — the resolve path.
- New `src/services/result_store.rs`:
  - `pub struct ResultStoreService { pools: DbPoolMap, ... }` (mirror
    `KeychainService`).
  - `pub async fn put(&self, eid, body: PutResultBody) -> Result<ResultPutResponse>`
    — generates snowflake id, computes sha256+bytes, formats the
    `noetl://execution/<eid>/result/<name>/<id>` URI, inserts the
    row, returns the response.
  - `pub async fn resolve(&self, parsed_ref: NoetlRef) -> Result<serde_json::Value>`
    — looks up the row, returns the `data` jsonb.
  - URI parser: `pub fn parse_noetl_ref(s: &str) -> Result<NoetlRef>`
    — destructures `noetl://execution/<eid>/result/<name>/<id>`
    into typed parts; rejects malformed URIs cleanly. Unit-test it
    against the worker's actual emit shape.
- New `src/handlers/result_store.rs`:
  - `PUT /api/result/{execution_id}` body
    `PutResultBody { name, data, scope, source_step? }` → 200
    with `ResultPutResponse` JSON. Maps shard-aware pool via
    `execution_id` (see how `executions::get` resolves the pool).
  - `GET /api/result/resolve?ref={uri}` → 200 with the resolved
    JSON payload directly (matches the worker's expectation —
    the response body IS the data, not a wrapper).
  - Return 404 if the row doesn't exist; 400 on malformed URI.
- Route registration in `src/main.rs` alongside the existing
  `executions_routes` / `replay_routes` blocks.
- Span + metric per `agents/rules/observability.md` Principle 1:
  - Span name `result_store.put` / `result_store.resolve` with
    `execution_id`, `name`, `bytes` as fields.
  - Counter `noetl_result_store_put_total{status}` and histogram
    `noetl_result_store_put_duration_seconds`.
  - Counter `noetl_result_store_resolve_total{status}` and histogram
    `noetl_result_store_resolve_duration_seconds`.

## Out of scope for this round

- Arrow Flight gRPC fast path (`flight_server.py`'s 562 LoC).
  Defer to a follow-up sub-issue if the HTTP fallback turns out to
  be a perf bottleneck.
- Tiered storage (disk / S3 / GCS). Single PG-blob tier only.
- GC + tracker. Single row per result; manual cleanup OK.
- `DELETE /api/result/{execution_id}` and `GET /api/result/{eid}/list`
  endpoints. Worker doesn't call them.
- Per-tenant scoping. Single-tenant for MVP; the `scope` field
  rides through as a string but isn't enforced.
- `expires_at` handling. Always NULL in MVP.

## Phases

### Phase A — read-only survey (no writes)

1. Read `repos/noetl/noetl/server/api/result/endpoint.py` end-to-end
   to capture the exact PUT body shape + response shape Python uses
   today.  Note any field-name divergence from what the worker
   sends.
2. Read the worker call site
   (`repos/worker/src/client/control_plane.rs:557-594`) and the
   build site
   (`repos/worker/src/executor/command.rs:813-890`) to confirm the
   wire shape you must satisfy.  Quote the JSON in your result.
3. Read `repos/server/src/services/secret_audit.rs` +
   `repos/server/src/db/queries/secret_audit.rs` +
   `repos/server/src/handlers/secret_audit.rs` to anchor on the
   server-owned-table pattern.
4. Confirm `repos/server/src/db/queries/result_store.rs` does NOT
   exist today (the previous session's grep said no — but verify).

### Phase B — implement + tests (local-only)

5. Implement the four files above (`db/queries/result_store.rs`,
   `services/result_store.rs`, `handlers/result_store.rs`, route
   wire-up in `main.rs`), plus the `CREATE TABLE IF NOT EXISTS`
   call at startup (next to the existing `secret_audit` one).
6. Add unit tests:
   - `parse_noetl_ref` accepts the worker's emit shape +
     rejects garbage (5-6 cases).
   - `ResultStoreService::put` round-trips through resolve (mocked
     pool or in-memory SQLite shim — whatever the rest of the
     codebase uses for service tests; `secret_audit_service.rs`
     tests are the precedent).
7. Add an integration test (under `tests/`) if the codebase has
   an integration-test scaffold for the existing
   `secret_audit` endpoints — otherwise unit tests are enough.
8. `cargo test --lib`, `cargo build --release --bin noetl-control-plane`.
   Capture the test counts (was 568/0/0 from earlier today on the
   v2.57.2 release).
9. Run `cargo clippy --lib --tests --release -- -D warnings` for
   parity with CI.

### Phase C — open PR (single push to a feature branch)

> *** Run only after explicit human go-ahead. Wait phrase: `ship it`. ***

10. Branch name: `feat/result-store-put-resolve-endpoints`.
11. Single commit titled
    `feat(api): port PUT /api/result/<eid> + GET /api/result/resolve from Python`.
    Commit body should cite `Closes noetl/ai-meta#70`.
12. Push to `origin/feat/result-store-put-resolve-endpoints`.
    No force.
13. Open PR on `noetl/server` with:
    - Title matching the commit subject.
    - Body summarising: scope, wire contract, scope-out list,
      kind re-val plan ("after merge, the #69 kind re-val
      [`test_output_select.yaml`, `test_storage_tiers.yaml`] is
      expected to reach `playbook.completed`").
    - `Closes noetl/ai-meta#70` keyword in the PR body so the
      issue auto-closes on merge.
14. Report the PR URL in the final report.

## FINAL REPORT

Write `round-01-result.md` with frontmatter and a per-phase
report.  Status:

- `complete` — all phases attempted and reported.  Phase C
  reports its blocked status if no go-ahead given.
- `partial` — Phase A + B done, Phase C couldn't proceed for
  reasons unrelated to the gate (e.g. cargo test failure that
  blocked the PR).
- `blocked` — couldn't even start (preconditions missing).

Required sections in the result:

```markdown
## Phase A — read-only survey
- Quote the exact JSON shapes the worker sends + expects back.
- Confirm the four scaffolding files (secret_audit + result_store
  precedents) exist where the prompt says they do.

## Phase B — implement + tests
- File-by-file change summary.
- `cargo test --lib` output (test counts).
- `cargo build --release` outcome.
- `cargo clippy` warnings, if any.

## Phase C — open PR
- Either: PR URL + commit SHA + branch name.
- Or: "phase C blocked: awaiting `ship it`".

## Issues observed
- Anything surprising.  Include grep-able fingerprints (SQL error
  strings, route conflicts, type mismatches).  Do NOT paraphrase.

## Manual escalation needed
- Anything you couldn't complete unattended, with the precise
  command(s) a human should run.
```

## Hard rules for this thread

- Never push to `origin/main` on any repo.  PRs only; landing them
  is the human's call.
- Never force-push.
- Never merge PRs yourself.
- Respect `AGENTS.md` and the rules under `agents/rules/` — especially
  `agents/rules/observability.md` (span + metric + execution_id per
  Principle 1), `agents/rules/safety.md` (public repo: no secrets),
  and `agents/rules/data-access-boundary.md` (workers go through
  the server, so this endpoint's auth model must match the
  internal-API token pattern the worker already uses for
  `/api/events` etc.).
- Do not store secrets in any file under ai-meta.
- Do not invent migration files; use the startup-time
  `CREATE TABLE IF NOT EXISTS` pattern from `secret_audit`.
- If a step's preconditions aren't met, stop and report.  Do not
  improvise around blockers.
- When in doubt about the wire shape, trust the worker's emit
  (`repos/worker/src/client/control_plane.rs`) over the Python
  reference — the worker has been calling this endpoint for
  months and its expectations are the source of truth.
