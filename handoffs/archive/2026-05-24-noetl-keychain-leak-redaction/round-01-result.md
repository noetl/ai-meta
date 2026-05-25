---
thread: 2026-05-24-noetl-keychain-leak-redaction
round: 1
from: codex
to: claude
created: 2026-05-24T20:00:36Z
in_reply_to: round-01-prompt.md
status: complete
---

## Phase A — audit

Synced `repos/noetl` and `repos/noetl-wiki` before branching. Live
pre-fix probe used execution `634023187587531501` through a local
port-forward and printed only key paths plus `<REDACTED-IN-REPORT>`.
It found 73 secret-bearing response paths under
`GET /api/executions/{id}/status`.

Audit table:

| Endpoint | Field | Leak class observed / possible |
|---|---|---|
| `GET /api/executions/{id}/status` | `variables` | Observed keychain values, provider token aliases, user bearer/JWT-shaped values, and signed/provider URL values. |
| `GET /api/executions/{id}` | included events, `result`, `error` | Event contexts/results can carry the same values as status reconstruction. |
| `GET /api/executions/{id}/events` | `events[*].context`, `events[*].result`, `events[*].error` | Stored event payloads can include rendered auth context, tool results, and error text. |
| `GET /api/vars/{id}` | `variables[*].value` | Transient variable values can include user bearer tokens and resolved keychain values. |
| `GET /api/vars/{id}/{var_name}` | `value` | Single variable read has the same surface as the list endpoint. |
| `GET /api/result/{execution_id}/{step_name}` | resolved body, `preview`, `extracted`, `correlation` | Result store payloads and previews can contain provider responses or signed URLs. |
| `POST /api/result/resolve` | resolved body | Direct result-reference resolution can return raw stored payloads. |
| `GET /api/temp/{execution_id}/{name}` | resolved body, `preview`, `correlation` | Temp-store payloads can contain rendered or tool-returned secrets. |
| `POST /api/temp/resolve` | resolved body | Direct temp-reference resolution can return raw stored payloads. |
| `GET /api/replay/state` | replayed state | Replay can fold event payloads back into state. |
| `GET /api/aggregate/loop/results` | aggregate response body | Aggregated loop results can include nested tool outputs. |
| `POST /api/context/render` | `rendered` | Rendered context can include resolved credential substitutions. |
| `GET /api/event*` | event `context`, `meta` | Broker read endpoints return event-shaped debug payloads. |
| `GET /api/commands/{event_id}` | command `context`, `meta` | Read-only command debug endpoint returns stored command context. |
| `GET /api/events/batch/{request_id}/status` and stream | status body | Batch request state can include error/message fields from payload context. |
| `POST /api/executions/{id}/analyze*` | DB rows, bundle, AI raw output/report | Analyze flows assemble event/result rows for clients and AI analysis. |
| GraphQL `executePlaybook` | none found in `repos/noetl` | Search did not find a GraphQL/strawberry endpoint in the server repo. |

Storage shapes reviewed: `workflow_state` via the engine state store,
`event` / `event_log`, `execution`, `command`, result store refs, temp
store refs, aggregate/replay projections. The fix intentionally leaves
stored data unchanged.

## Phase B — helper + detection strategy

Added `redact_keychain_values()` in `noetl/core/sanitize.py`. The helper
accepts arbitrary nested data, returns a redacted copy, and keeps the
shared placeholder `[REDACTED]`.

Detection uses both key and value checks:

- Key checks cover token, secret, api_key, password, authorization,
  keychain, credential, and private-key field names.
- Value checks cover bearer/basic auth headers, JWT-shaped strings,
  common provider-key prefixes, private-key headers, and URLs carrying
  credential-bearing query parameters.
- Optional caller-provided secret values are redacted by exact or
  embedded match.

Unit coverage was added in `tests/core/test_redact_keychain_values.py`
for nested keychain data, user bearer/JWT values, secret-shaped
intermediate values, embedded known values, idempotence, and non-secret
passthrough.

## Phase C — endpoints patched

Patched serialization boundaries in:

- `noetl/server/api/core/execution.py`
- `noetl/server/api/execution/endpoint.py`
- `noetl/server/api/vars/endpoint.py`
- `noetl/server/api/result/endpoint.py`
- `noetl/server/api/temp/endpoint.py`
- `noetl/server/api/context/endpoints.py`
- `noetl/server/api/aggregate/endpoint.py`
- `noetl/server/api/replay/endpoint.py`
- `noetl/server/api/broker/service.py`
- `noetl/server/api/core/batch.py`
- `noetl/server/api/core/commands.py`

Worker claim and runtime execution paths were left unchanged so workers
still receive the data needed to execute claimed commands.

Tests added or updated:

- `tests/core/test_redact_keychain_values.py`
- `tests/api/test_vars_response_redaction.py`
- `tests/api/execution/test_status_endpoint_parity.py`

Draft PR opened: https://github.com/noetl/noetl/pull/603

## Phase D — live validation

Pre-fix sanitized probe:

```text
GET /api/executions/634023187587531501/status
finding_count 73
variables.keychain = <REDACTED-IN-REPORT>
variables.keychain.openai_token.api_key = <REDACTED-IN-REPORT>
variables.keychain.anthropic_token.api_key = <REDACTED-IN-REPORT>
variables.openai_token.api_key = <REDACTED-IN-REPORT>
variables.anthropic_token.api_key = <REDACTED-IN-REPORT>
provider URL fields under variables.* = <REDACTED-IN-REPORT>
```

Built and deployed:

- Cloud Build ID: `9799767b-f91c-4f95-98a8-b371d3a607e2`
- Image:
  `us-central1-docker.pkg.dev/noetl-demo-19700101/noetl/noetl:keychain-redaction-69d55d40-20260524125244`
- Helm release: `noetl`, namespace `noetl`, revision `158`
- Rollout: `deployment "noetl-server" successfully rolled out`
- Health: `{"status":"ok"}`

Post-fix sanitized probe against the same execution:

```text
GET /api/executions/634023187587531501/status
finding_count 0
variables.keychain = <REDACTED-PLACEHOLDER-SEEN>
variables.openai_token = <REDACTED-PLACEHOLDER-SEEN>
variables.anthropic_token = <REDACTED-PLACEHOLDER-SEEN>
variables.openai_secret_path = <REDACTED-PLACEHOLDER-SEEN>
variables.anthropic_secret_path = <REDACTED-PLACEHOLDER-SEEN>
```

Validation commands/results:

- `python -m py_compile` on touched modules: pass.
- Focused pytest:
  `tests/core/test_redact_keychain_values.py`,
  `tests/api/execution/test_status_endpoint_parity.py`,
  `tests/api/test_vars_response_redaction.py`: `15 passed`.
- API-focused pytest `tests/api tests/core/test_redact_keychain_values.py`:
  `126 passed`, `3 failed`. The failures are pre-existing-looking
  issues in replay fixture stage IDs and worker locator expectations,
  not this patch's redaction surface.
- Full `pytest tests/`: collection stopped before execution with five
  existing collection errors for missing modules/fixture:
  `noetl.tools.tools`, `noetl.tools.shared`,
  `noetl.server.stuck_execution_reaper`, `noetl.tools.auth`, and
  `tests/fixtures/playbook_test_config.yaml`.

## Phase E — wiki update

Updated and pushed `repos/noetl-wiki`:

- Commit: `210b1c69d19399bca2fbd3a9d1d10fdaccbae6d7`
- Page: https://github.com/noetl/noetl/wiki/secrets-and-redaction
- Updated `Home.md` and `_Sidebar.md`.

Also updated `agents/rules/execution-model.md` to cross-link the wiki
page from the secrets-and-credentials rule.

## Issues observed

- Storage-side hygiene remains open: resolved credential values can
  still exist in workflow state, event payloads, command context, result
  refs, or temp refs. This round masks reads; it does not alter storage
  behavior.
- Full pytest collection is currently blocked by missing legacy modules
  and a missing playbook regression fixture.
- API-focused tests still have unrelated failures around replay fixture
  stage IDs and worker locator expectations.
- The live cluster currently runs the temporary validation image tag
  `keychain-redaction-69d55d40-20260524125244`. Keep or roll forward to
  the eventual reviewed release tag deliberately.

## Manual escalation needed

- Review draft PR https://github.com/noetl/noetl/pull/603. Do not merge
  until reviewers are satisfied with the response-boundary coverage.
- Decide whether to keep the temporary GKE image running until merge or
  replace it with the next reviewed image tag.
- Open a follow-up for storage-side hygiene so resolved credential
  values are not persisted where runtime behavior can safely avoid it.
