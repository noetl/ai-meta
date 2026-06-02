---
slug: 2026-06-02-nats-tool-kind
round: 01
status: complete
tracks: noetl/ai-meta#38
pr: https://github.com/noetl/tools/pull/12
branch: feature/nats-tool-kind
date: 2026-06-01
---

## Implementation

New file: `repos/tools/src/tools/nats.rs` (line 1–720 approx).

`NatsTool` implements all 13 operations:
- KV: `kv_get`, `kv_put`, `kv_delete`, `kv_keys` (glob filter via `pattern`), `kv_purge`
- Object Store: `object_get`, `object_put`, `object_delete`, `object_list`, `object_info`
- JetStream: `js_publish` (optional headers), `js_get_msg` (by `seq` / `last: true` / `subject`), `js_stream_info`

Auth resolution chain (`resolve_connection`) mirrors `PostgresTool`: credential alias via `ctx.get_secret()` first; explicit `url` / `user` / `password` / `token` fields second.  Credential JSON must contain `url`.

Observability: `nats.op` tracing span with `operation` + `execution_id` attributes; duration recorded in `ToolResult.duration_ms`.

## Registration

`repos/tools/src/tools/mod.rs`: added `mod nats`, `pub use self::nats::NatsTool`, and `registry.register(NatsTool::new())`.

`repos/tools/Cargo.toml`: added `async-nats = "0.38"`, `bytes = "1"`, `futures = "0.3"`.

## Tests

16 new unit tests in `tools::nats::tests`:
- Config parsing (kv_get, kv_put+ttl, js_publish, object_get+base64, js_get_msg variants)
- Auth resolution (explicit URL, missing URL error, credential alias, alias missing url)
- Helpers: serialize_value, encode_object_data (utf-8 + base64), glob_match
- Tool name assertion

1 integration test (`test_nats_integration_kv_roundtrip`) gated behind `NOETL_TEST_NATS_URL` env var — skips silently when not set.

`cargo test --lib`: 170 passed, 0 failed.
`cargo clippy --all-targets`: 0 new warnings from `nats.rs`.

## Wiki

New page: `repos/noetl-tools-wiki/nats-tool.md` — config shape, credential shape, full operations table, worked example, observability note.

Cross-linked from `repos/noetl-tools-wiki/Home.md` (tool-kinds table + Pages section) and `_Sidebar.md`.

Pushed to `noetl/tools.wiki.git` at `867fc53`.

## PR

https://github.com/noetl/tools/pull/12 — branch `feature/nats-tool-kind`, base `main`.

## Blockers

None.  Worker-side wiring (`noetl/worker` dispatch registration of the `Nats` variant) is out of scope for this round — tracked as the sibling PR mentioned in noetl/ai-meta#38.
