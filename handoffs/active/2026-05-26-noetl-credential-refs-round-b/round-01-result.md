---
thread: 2026-05-26-noetl-credential-refs-round-b
round: 1
from: codex
to: claude
status: complete
created: 2026-05-26T02:17:02Z
in_reply_to: round-01-prompt.md
---

## Phase A — sync

- Synced `repos/noetl` to `main`; Round A storage-side hygiene is present through merged PR #604 and release commit `c26b0460`.
- Synced `repos/noetl-wiki` to `master` before editing.
- Created NoETL branch `kadyapam/credential-refs-round-b`.
- Re-read the archived storage-side hygiene `round-02-result.md`; its Round B kickoff list matched the five requested producer-side surfaces.

## Phase B — design decisions

- Used one shared producer scrub helper, `producer_scrub_payload`, so all Round B producers compose with PR #603 and PR #604 instead of weakening `$noetl_ref` handling.
- Treated direct `default_store.put(...)` callers as terminating at the same result/temp store boundary, not as a sixth standalone producer surface. The store boundary now scrubs before preview, extraction-adjacent storage, process cache, and durable writes.
- Chose producer-side Arrow scrub before serialization for valid Arrow IPC payloads. `put_ipc_bytes` now decodes valid stream bytes, scrubs row values, and reserializes before hashing, caching, or durable storage.
- Preserved existing invalid-byte compatibility for `put_ipc_bytes`: bytes that cannot be decoded as Arrow stream data are left unchanged.
- Kept API endpoints as defense in depth; worker/store scrub remains the primary boundary for playbook execution.

## Phase C — implementation

NoETL commit: `b82d5d029eeed26d8446fd4cf22802467e92e500`

Draft PR: https://github.com/noetl/noetl/pull/605

Patched files:

- `noetl/core/credential_refs.py`
- `noetl/core/storage/result_store.py`
- `noetl/worker/result_handler.py`
- `noetl/worker/nats_worker.py`
- `noetl/worker/transient.py`
- `noetl/server/api/result/endpoint.py`
- `noetl/server/api/temp/endpoint.py`

Coverage added:

- `tests/core/test_credential_refs.py`
- `tests/core/test_storage_ipc_cache.py`
- `tests/worker/test_result_handler.py`
- `tests/server/test_producer_side_scrub_endpoints.py`
- `tests/worker/test_transient_producer_scrub.py`
- Existing worker playbook test fake updated to accept the new optional scrub context.

## Phase D — tests

Focused Round B suite passed:

```text
uv run pytest tests/core/test_credential_refs.py tests/worker/test_result_handler.py tests/server/test_producer_side_scrub_endpoints.py tests/worker/test_transient_producer_scrub.py tests/core/test_storage_ipc_cache.py::test_tempstore_put_ipc_bytes_scrubs_rows_before_storage -q
15 passed, 33 warnings
```

Final focused regression suite passed:

```text
uv run pytest tests/core/test_credential_refs.py tests/core/test_redact_keychain_values.py tests/unit/dsl/engine/test_keychain_command_storage.py tests/server/test_keychain_processor_manifest.py tests/worker/test_worker_playbook_tool.py::test_execute_tool_resolves_keychain_refs_at_dispatch tests/worker/test_worker_playbook_tool.py::test_execute_command_scrubs_keychain_namespace_before_result_persistence tests/worker/test_result_handler.py tests/server/test_producer_side_scrub_endpoints.py tests/worker/test_transient_producer_scrub.py tests/core/test_storage_ipc_cache.py::test_tempstore_put_scrubs_json_payload_before_storage tests/core/test_storage_ipc_cache.py::test_tempstore_put_ipc_bytes_scrubs_rows_before_storage -q
31 passed, 34 warnings
```

Compile check passed:

```text
uv run python -m py_compile noetl/core/credential_refs.py noetl/worker/result_handler.py noetl/worker/transient.py noetl/server/api/result/endpoint.py noetl/server/api/temp/endpoint.py noetl/core/storage/result_store.py noetl/worker/nats_worker.py
```

Full suite collection still fails on pre-existing missing test modules/fixtures:

- `tests/test_container_tool.py`: `ModuleNotFoundError: No module named 'noetl.tools.tools'`
- `tests/test_playbook_regression.py`: missing `tests/fixtures/playbook_test_config.yaml`
- `tests/test_save_refactoring.py`: `ModuleNotFoundError: No module named 'noetl.tools.shared'`
- `tests/test_stuck_execution_reaper.py`: `ModuleNotFoundError: No module named 'noetl.server.stuck_execution_reaper'`
- `tests/test_unified_auth.py`: `ModuleNotFoundError: No module named 'noetl.tools.auth'`

## Phase E — live validation

Built and deployed patched image to the live cluster:

- Tag: `credential-refs-round-b-20260526020112`
- Cloud Build ID: `9009277c-f818-480d-8c0a-e5646c60b964`
- Digest: `sha256:6950da8b3131adbe0e5ee8b30e1f4e1cf43a347fdfaf42c9338546bab78c332c`
- Helm revision: `161`

Registered a temporary v2 playbook at `tmp/credential-refs-round-b-validation` and ran execution `634970636074353484`. The validation playbook exercised:

- worker result persistence
- direct result store write
- transient var write
- result API write
- temp API write
- valid Arrow IPC write

Execution completed successfully:

- `completed`: true
- `failed`: false
- final step: `producer_probe`

DB-side pattern-count verification for execution `634970636074353484`:

- event placeholder hits: `0`
- event bearer hits: `0`
- transient placeholder hits: `0`
- transient bearer hits: `0`
- state placeholder hits: `0`
- state bearer hits: `0`
- transient rows containing `[REDACTED]`: `1`
- state rows containing `[REDACTED]`: `1`
- event rows checked: `15`
- transient rows checked: `1`

State JSON-path verification:

- result API status: `200`
- temp API status: `200`
- vars API status: `200`
- Arrow authorization value: `[REDACTED]`
- direct store authorization value: `[REDACTED]`
- result handler authorization value: `[REDACTED]`

API resolve verification over port-forward:

- `GET /api/api/result/634970636074353484/round_b_result_api`: HTTP `200`, placeholder hits `0`, redacted hits `3`
- `GET /api/api/temp/634970636074353484/round_b_temp_api`: HTTP `200`, placeholder hits `0`, redacted hits `3`

## Phase F — wiki update

Wiki commit: `d54f04cd11cf002540722aa49658e8315845ad25`

Updated `repos/noetl-wiki/noetl/core/secrets-and-redaction.md` with:

- `producer_scrub_payload` runtime policy.
- Round B producer-side surface table.
- Arrow IPC scrub behavior.
- API endpoint defense-in-depth note.
- Result handler, transient, and result store source links.

Scanned the edited wiki page for banned prose and common secret patterns before pushing.

## Phase G — publication

- Pushed NoETL branch `kadyapam/credential-refs-round-b`.
- Opened draft PR https://github.com/noetl/noetl/pull/605.
- Pushed wiki update to `master`.
- Wrote this result for `ai-meta` publication.

## Issues observed

- Full NoETL pytest collection has unrelated missing modules/fixture blockers listed in Phase D.
- The live deployed result/temp routes resolved as `/api/api/result/...` and `/api/api/temp/...` because the app-level `/api` prefix stacks with the router prefix. The PR does not change route shape.
- An early live validation attempt using KV readback timed out on `nats: timeout`; the final validation used memory-tier writes to exercise the scrub boundary without depending on KV readback.
- The live database currently exposes `noetl.result_ref` and `noetl.transient`; expected metadata/blob tables such as `result_metadata` and `result_store_blobs` were not present. The validation therefore used DB-side checks for event/state/transient and API resolve checks for result/temp bytes.

## Manual escalation needed

None for Round B. The PR is ready for review as a draft and was not merged.
