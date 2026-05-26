---
thread: 2026-05-24-noetl-storage-side-credential-hygiene
round: 2
from: codex
to: claude
status: complete
created: 2026-05-26T01:01:54Z
in_reply_to: round-02-prompt.md
---

# Round 02 Result

Implemented **Round A only**: command/state persistence plus worker dispatch.
Round B producer-side hardening remains out of scope.

## Phase A - Sync And Scope

- Synced `repos/noetl` to `main` at `f051d9c2`.
- Synced `repos/noetl-wiki` to `master` at `210b1c6`.
- Re-read `round-01-result.md`; treated its audit table and design as approved.
- Created `repos/noetl` branch `kadyapam/storage-side-credential-hygiene-round-a`.

## Phase B - Implementation

NoETL commit:

- `862303d89bc1cc4d34edc482b4f0d16bde7cc6c7`
- Branch: `kadyapam/storage-side-credential-hygiene-round-a`
- Draft PR: https://github.com/noetl/noetl/pull/604

Changes:

- Added `noetl/core/credential_refs.py` for storage-safe keychain manifests, `$noetl_ref` objects, deferred mixed keychain templates, namespace stripping, and worker-side resolution.
- Updated keychain startup processing so resolved values stay in `noetl.keychain`; workflow state receives only `_keychain_manifest`.
- Updated execution state serialization and render-context construction to strip `keychain` and keychain-entry namespaces while preserving the manifest.
- Updated command creation to store pure keychain expressions as `$noetl_ref` and leave mixed expressions deferred until worker dispatch.
- Updated worker dispatch to resolve references in memory immediately before tool execution.
- Stripped `keychain` namespaces from worker result payloads before result handling and event emission.
- Removed a worker debug log that previously exposed resolved keychain entry content; it now logs names only.

Round B was not implemented. I did not touch result/temp store producer paths or Arrow IPC producer handling.

## Phase C - Tests

Passed:

```bash
uv run pytest tests/core/test_credential_refs.py tests/core/test_redact_keychain_values.py tests/unit/dsl/engine/test_keychain_command_storage.py tests/server/test_keychain_processor_manifest.py tests/worker/test_worker_playbook_tool.py::test_execute_tool_resolves_keychain_refs_at_dispatch tests/worker/test_worker_playbook_tool.py::test_execute_command_scrubs_keychain_namespace_before_result_persistence -q
```

Result: `20 passed, 13 warnings`.

Passed:

```bash
uv run python -m py_compile noetl/core/credential_refs.py noetl/server/keychain_processor.py noetl/core/dsl/engine/executor/lifecycle.py noetl/core/dsl/engine/executor/state.py noetl/core/dsl/engine/executor/commands.py noetl/core/dsl/engine/executor/transitions.py noetl/worker/nats_worker.py noetl/worker/keychain_resolver.py
```

Note: an earlier full-file run of `tests/worker/test_worker_playbook_tool.py`
still hit the existing `inline_max_bytes` assertion mismatch seen outside this
patch. The new worker tests passed directly.

## Phase D - Live Validation

Live GKE validation used the pre-authorized cluster path.

- Context: `gke_noetl-demo-19700101_us-central1_noetl-cluster`
- Image: `us-central1-docker.pkg.dev/noetl-demo-19700101/noetl/noetl:storage-refs-round-a-20260526005308`
- Cloud Build: `a4cc2405-46ae-4f23-86b2-86567a5d7aef`
- Image digest: `sha256:6f2029521ef5a2cf8696a983e9e3c5f43af6fe74b95f4ab573cec359885493db`
- Helm release: `noetl`, revision `160`
- Rolled out `noetl-server` and `noetl-worker`.

Temporary playbook:

- Registered path: `tmp/storage-side-credential-hygiene-round-a`
- Registered version: `2`
- The playbook exercised both a pure keychain expression and a mixed
  `Bearer {{ ... }}` expression.

Three distributed executions completed:

- `634932706026980051`
- `634932719557804767`
- `634932733440951033`

DB-side verification across those executions:

- Event provider-key pattern hits: `0`
- Command provider-key pattern hits: `0`
- Execution state provider-key pattern hits: `0`
- Command rows containing `$noetl_ref`: `3`
- Command rows containing deferred mixed keychain template: `3`
- Rows with manifest present: events `9`, execution state `3`
- Provider success rows: `9`
- Persisted `keychain` namespace rows in event contexts/results: `0`
- Persisted `keychain` namespace rows in execution state: `0`

I used count/pattern queries only and did not dump secret-bearing payloads.

## Phase E - Wiki

Updated `repos/noetl-wiki/noetl/core/secrets-and-redaction.md`.

- Wiki commit: `aad9b64be4e57a3024250c2fffe273a1f51af76a`
- Pushed to `noetl/noetl.wiki.git` `master`

The wiki now documents:

- keychain manifest storage in workflow variables,
- pure keychain expression storage as `$noetl_ref`,
- mixed keychain expression deferral to worker dispatch,
- worker-side in-memory resolution,
- Round B producer-side surfaces that remain open.

## Phase F - PR

Opened draft PR and did not merge:

- https://github.com/noetl/noetl/pull/604

The PR body includes the Round A scope boundary, test commands, live validation
image/build details, execution IDs, and DB-side count results. It does not
include secret values.

## Hygiene

- No service-account JSON, Firebase API key, provider API key, private key, or
  leaked value was written to ai-meta, the wiki, commits, or the PR body.
- Scanned touched NoETL files, tests, wiki page, and this result for common
  secret patterns before commit/push.
- No PR was merged.
- No force-push was used.

## Round B Kickoff List

Round B should cover producer-side handling for:

- result previews,
- extracted fields,
- transient variables,
- caller-provided result API writes,
- caller-provided temp API writes,
- Arrow IPC payloads.

That work should use schema-aware handling before serialization and should not
be widened into this Round A patch.
