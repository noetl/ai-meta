# Event Projection Audit

## 1. Baseline Bug Summary

Baseline: noetl/noetl#417, `fix(worker): preserve agent diagnosis in event context`, merged as `032c7e850e3e497841cdc1550e9e7d6648b2092f` on 2026-05-05.

The v2.35.8 regression lived in the worker's event projection layer. Agent steps produced a nested envelope containing `error.diagnosis`, but `NATSWorker._extract_control_context()` only retained scalar fields from nested dictionaries. That meant `result.context.error.kind`, `result.context.error.message`, and similar scalar fields survived, while `result.context.error.diagnosis` was silently dropped before persistence. PR #417 added an explicit `error.diagnosis` carve-out so the scalar diagnosis fields survive inside the nested diagnosis object.

The pattern to watch for is therefore: an execution-time result contains useful nested control metadata, but the worker or server event projection trims it to a strict reference/context envelope and drops non-scalar nested content.

## 2. Survey of Code Paths

- `repos/noetl/noetl/worker/nats_worker.py:453`-`517`: `_externalize_event_value_if_needed()` bounds large event fields by storing the original value in TempStore and replacing it with a reference wrapper.
- `repos/noetl/noetl/worker/nats_worker.py:541`-`576`: `_extract_reference_from_value()` extracts top-level `reference`, `_ref`, or `data_reference` objects into the strict event result envelope.
- `repos/noetl/noetl/worker/nats_worker.py:582`-`656`: `_extract_control_context()` is the main worker-side projection risk point. It blocks data-plane keys, keeps scalars, keeps reference dictionaries, and now specially preserves `error.diagnosis`.
- `repos/noetl/noetl/worker/nats_worker.py:658`-`673`: `_build_strict_result_envelope()` creates `{status, reference, context}` from a worker value.
- `repos/noetl/noetl/worker/nats_worker.py:702`-`741`: `_normalize_payload_reference_only()` selects `payload.result` or `payload.response`, builds the strict envelope, merges top-level context through `_extract_control_context()`, and strips transport-only fields.
- `repos/noetl/noetl/worker/nats_worker.py:1952`-`1978`: successful tool responses are processed through `ResultHandler` before event emission, allowing large responses to become references.
- `repos/noetl/noetl/worker/nats_worker.py:2000`-`2038`: generic `status in ("error", "failed")` coercion is skipped for `tool_kind == "agent"`, preserving the agent envelope for downstream steps.
- `repos/noetl/noetl/worker/nats_worker.py:2185`-`2211`: unhandled non-agent tool errors emit `call.error` plus terminal events using the processed response as the projected result payload.
- `repos/noetl/noetl/worker/nats_worker.py:2216`-`2251`: successful tools emit `call.done`, `step.exit`, and `command.completed` with the processed response as `result_payload`.
- `repos/noetl/noetl/worker/nats_worker.py:3174`-`3270`: `_emit_batch_events()` normalizes each event payload before posting to `/api/events/batch`; the fallback to individual events uses the same prepared payload.
- `repos/noetl/noetl/worker/nats_worker.py:3351`-`3415`: `_emit_terminal_event_batch()` assembles primary and tail terminal events; it does not project by itself.
- `repos/noetl/noetl/worker/nats_worker.py:2631`-`2652`: agent tools intentionally return the full agent envelope, including nested `error.diagnosis`.
- `repos/noetl/noetl/worker/nats_worker.py:2654`-`2663`: MCP tools return error envelopes unchanged, otherwise unwrap `data`; MCP result content is data-plane payload.
- `repos/noetl/noetl/server/api/core/events.py:40`-`57`: `_validate_reference_only_payload()` enforces the strict `{status, reference, context, command_id}` result envelope and rejects forbidden inline data keys.
- `repos/noetl/noetl/server/api/core/events.py:92`-`103`: `_collect_compact_context()` copies selected scalar transport fields; `_bounded_context()` preserves a context object wholesale if it is under the configured byte limit.
- `repos/noetl/noetl/server/api/core/commands.py:175`-`259`: `_build_reference_only_result()` is the server-side projection function used by `/events` and `/events/batch`; it preserves bounded context dictionaries and merges compact transport metadata.
- `repos/noetl/noetl/server/api/core/batch.py:118`-`212`: batch event insertion validates each worker payload, builds a reference-only result, and persists the JSON result.
- `repos/noetl/noetl/server/api/execution/endpoint.py:113`-`128`: `_deserialize_event_row()` JSON-decodes persisted `context` and `result` without further projection.
- `repos/noetl/noetl/server/api/execution/endpoint.py:131`-`184`: `_fetch_execution_events_page()` selects full `context` and `result` for execution detail/event APIs.
- `repos/noetl/noetl/server/api/execution/endpoint.py:569`-`620`: diagnostic collection uses `LEFT(context::text, 4000)` / `LEFT(result::text, 4000)` for bounded debug rows, not for the main execution detail path.
- `repos/noetl/noetl/server/api/execution/endpoint.py:1133`-`1317`: `get_execution()` returns paginated events from `_fetch_execution_events_page()` as `ExecutionEventResponse`.
- `repos/noetl/noetl/server/api/execution/endpoint.py:1320`-`1345`: `get_execution_events()` uses the same full event page fetch.

## 3. Findings

### CONFIRMED_BUG

- None found during this audit beyond the already-merged baseline fix in noetl/noetl#417. The specific `result.context.error.diagnosis` loss pattern is now covered in `NATSWorker._extract_control_context()` at `repos/noetl/noetl/worker/nats_worker.py:631`-`640`.

### POTENTIAL_RISK

- `repos/noetl/noetl/worker/nats_worker.py:623`-`642`: `_extract_control_context()` still reduces arbitrary nested dictionaries to scalar children unless the nested dictionary is a reference wrapper or the special `error.diagnosis` shape. That is safe for the currently reviewed contracts, but future nested control contracts would be dropped unless they get an explicit carve-out plus a parity smoke.
- `repos/noetl/noetl/worker/nats_worker.py:592`-`607`: blocked data-plane keys intentionally exclude `data`, `response`, `result`, `payload`, `rows`, and `columns` from context. This keeps event rows bounded, but any tool that stores semantic control state under one of those names must expose it through a reference or a reviewed control-context field.
- `repos/noetl/noetl/server/api/core/events.py:92`-`95`: `_collect_compact_context()` only copies an allow-list of top-level transport fields. That is appropriate as a compact merge, but it should not become the only persistence path for any future nested control payload.

### SAFE_BY_DESIGN

- Agent envelope: `repos/noetl/noetl/worker/nats_worker.py:2631`-`2652` preserves the full agent result, and `repos/noetl/noetl/worker/nats_worker.py:2000`-`2038` prevents generic error coercion from turning agent `status: "error"` into a step failure before downstream steps inspect the envelope.
- Agent diagnosis projection: `repos/noetl/noetl/worker/nats_worker.py:631`-`640` now preserves the nested scalar diagnosis dict at `result.context.error.diagnosis`.
- Task sequence errors: the reviewed error contract uses scalar `error.message` / `error.kind`, which survive the scalar nested-dict projection.
- MCP tool calls: `repos/noetl/noetl/worker/nats_worker.py:2654`-`2663` keeps error envelopes intact and unwraps successful `data`; large or structured MCP result content is data-plane output, not control context, and should be carried via `response` / references rather than `result.context`.
- Playbook `data.*`: data-plane output is intentionally blocked from strict event context and routed through result processing/reference preservation.
- Externalized payload branch: `repos/noetl/noetl/worker/nats_worker.py:453`-`517` stores the full value externally before emitting a reference wrapper, so projection does not discard the original large payload.
- Server write path: `repos/noetl/noetl/server/api/core/events.py:97`-`103` and `repos/noetl/noetl/server/api/core/commands.py:203`-`258` preserve bounded context dictionaries rather than scalarizing nested content.
- Execution read path: `repos/noetl/noetl/server/api/execution/endpoint.py:113`-`184`, `1133`-`1345` deserialize and return persisted JSON result/context without additional trimming.
- Diagnostic rows: `repos/noetl/noetl/server/api/execution/endpoint.py:569`-`620` intentionally truncates debug snapshots only; it is not the API path used by execution detail parity checks.

## 4. Fix PRs Landed In-Flight

- Phase B landed no new noetl fix PRs. The only confirmed event-projection bug found in this thread was already fixed before this task by noetl/noetl#417.
