---
thread: 2026-06-09-worker-predispatch-call-error
round: 2
from: claude
to: claude
created: 2026-06-10T20:55:00Z
in_reply_to: round-02-prompt.md
status: complete
---

# Result — completed directly by Claude (not Codex)

**Routing note.** Round 01 + 02 were written as Claude→Codex prompts,
but the user re-routed this work: *"Fix issue #78 directly yourself in
Rust — do NOT dispatch to Codex … the standing direction is Claude
writes Rust directly."*  This supersedes the round-01 predecessor note
that had routed it to Codex.  Per
[`agents/rules/handoff-routing.md`](../../../agents/rules/handoff-routing.md)
(Claude writes Rust directly), Claude implemented, built, tested,
kind-validated, opened + merged the PR, bumped the pointer, and updated
the wikis end-to-end.  The wait phrase `ship the worker fix` was
satisfied by the user's explicit "ship the full way … work
autonomously" instruction.

## Phase A — orientation + baseline

- `repos/worker` started at `8dd653b` (origin/main) with the expected
  pre-existing local mod: `Cargo.toml` `noetl-tools = { path =
  "../tools" }` + a `[patch.crates-io]` entry (round-02 superseded the
  round-01 "keep the path dep" instruction → revert both to
  `noetl-tools = "3"`).
- Branch `fix/predispatch-call-error` cut from `8dd653b`.
- Baseline after reverting the dep + `cargo update -p noetl-tools
  --precise 3.1.0`: `cargo build` clean; `cargo test` 126 lib + 9
  integration green.
- Read the four load-bearing files + `observability.md` /
  `execution-model.md`.

## Phase B — implement

The four-file failing path was confirmed exactly as briefed, with one
material correction to the diagnosis (see *Issues observed*).

- `src/executor/auth_alias.rs` — added typed `CredentialResolutionError`
  (`AliasNotFound` / `Transient` / `Invalid` + `is_terminal()`),
  `classify_fetch_error`, `is_retryable_status`.  `resolve_auth_alias` /
  `resolve_single_tool_alias` now return the typed error.
- `src/client/control_plane.rs` — added `CredentialHttpError` (carries
  the HTTP status); the two non-success `bail!` sites in
  `get_credential` / `get_sealed_credential` now return it so the
  classifier decides retryability by **code**, not by string-matching.
- `src/executor/command.rs` — `MAX_PREDISPATCH_ATTEMPTS = 3`;
  `handle_predispatch_failure` emits `call.error` + `command.failed`
  (matching the post-dispatch arm's payload) for terminal failures and
  for attempt-exhausted transients; both pre-dispatch call sites
  (`resolve_auth_alias`, `serde_json::from_value::<ToolConfig>`) route
  through it.
- `src/worker.rs` — kept the structured ERROR log; documented the
  invariant (terminal failures already emitted; the loop must NOT
  blanket-emit a safety-net terminal — that would double-emit terminals
  and defeat the retryable path).
- Dep revert folded in: `Cargo.toml` → `noetl-tools = "3"`, `Cargo.lock`
  → `noetl-tools 3.1.0`.

Tests: +7 (`alias_404…terminal`, `http_500_decryption…terminal`,
`http_503…retryable`, `transport_error…retryable`,
`unsupported_credential_type…terminal`,
`predispatch_terminal_failure_emits_call_error`,
`predispatch_retryable_failure_emits_nothing`).  Final:
`cargo fmt` + `cargo clippy --all-targets` (no new findings; the two
pre-existing warnings on `emit_event_via` / a test helper are
unchanged) + `cargo build` + `cargo test` → **133 lib + 9 integration
green**.  Diff scoped to 6 files.

## Phase C — kind revalidation

- Rebuilt `localhost/noetl-worker:dev` (the dep revert is what lets the
  Docker build resolve `noetl-tools` from crates.io — the path dep
  can't see `../tools` in the build context), `podman save | kind load
  image-archive --name noetl`, `kubectl -n noetl rollout restart
  deploy/noetl-worker-rust`.
- **Negative (the bug):** registered `test/postgres` (fixture
  `repos/e2e/fixtures/playbooks/postgres_test.yaml`, `auth:
  "pg_noetl_k8s"`), executed distributed (execution
  `323198641718169600`).  Event log:
  `playbook_started → command.issued → command.claimed →
  command.started → call.error(FAILED) → command.failed(FAILED) →
  playbook.failed(FAILED)`.  No hang; no manual `noetl cancel` needed
  (contrast the pre-fix repro).  Worker log fingerprint:
  `Pre-dispatch failure is terminal; emitted call.error +
  command.failed so the execution fails cleanly instead of hanging at
  command.started … error=credential fetch for 'pg_noetl_k8s' failed:
  HTTP 500 {"error":"Decryption failed: aead::Error","status":500}`.
- **Positive regression:** `hello_world` (execution
  `323199037668855808`) → `playbook.completed`, all steps
  `call.done`/`command.completed`/success.
- **Transient-stays-retryable:** covered by unit tests
  (`http_503…`, `transport_error…`,
  `predispatch_retryable_failure_emits_nothing`).  Live-injecting a
  flaky keychain 503 isn't feasible without fault injection.

## Phase D — wiki update

`repos/noetl-worker-wiki/worker-credentials.md` gained a *Pre-dispatch
failure handling — terminal vs retryable* section (classification table
+ live-repro note + Source links).  Pushed as `987abba`.

## Phase E — sub-issue + push + PR

- Tier-2 sub-issue [noetl/worker#67](https://github.com/noetl/worker/issues/67)
  opened (`Tracks noetl/ai-meta#78`); auto-closed by the PR.
- PR [noetl/worker#68](https://github.com/noetl/worker/pull/68)
  (`Closes noetl/worker#67`, `Refs noetl/ai-meta#78`) opened under
  `kadyapam`, merged (squash) → worker `main` `99e2c66`.
- ai-meta pointer bump `3841367` (worker `99e2c66` + worker-wiki
  `987abba` + ai-meta-wiki `5b862f1`), `Closes noetl/ai-meta#78`.
- ai-meta wiki dashboard (`5b862f1`): Home (Active→Recently closed +
  Last-refreshed), Sessions-Log, Releases (worker v5.15.1 row).
- [noetl/ai-meta#78](https://github.com/noetl/ai-meta/issues/78) closed
  with the audit comment; roadmap board 3 item → Done (auto).

## Issues observed

- **Diagnosis correction (load-bearing).** The umbrella + both prompts
  framed this as a "clean 404" terminal case (`auth_alias.rs:161`,
  `GET /api/keychain/pg_noetl_k8s → 404`).  The worker has **no**
  `/api/keychain/` call — it resolves aliases via
  `GET /api/credentials/{alias}`.  The actual live failure is
  `HTTP 500 {"error":"Decryption failed: aead::Error","status":500}`
  (sealing off; `WORKER_ID` empty; the credential record exists but its
  ciphertext can't be decrypted server-side).  The observed worker log
  `error=looking up credential alias 'pg_noetl_k8s' in keychain` was the
  old `.with_context` (transport/Err arm), not the `None`/404 arm.  A
  naive "all non-404 HTTP = retryable" split would have classified the
  500 as `Transient` → no emit on attempts=0 → still hangs.  The fix
  therefore classifies by HTTP **status code**: terminal for
  404/400/401/403/500, retryable only for 408/429/502/503/504 +
  transport errors.  This handles both the briefed 404 and the real
  500.
- Two pre-existing `clippy --all-targets -D warnings` failures
  (`emit_event_via` 8/7 args; an `or_else(|x| Err(y))` in a
  control_plane test helper) exist on baseline `8dd653b` under the
  local clippy (rust-1.92.0).  Left untouched (out of scope; repo CI
  uses an older clippy).
- `noetl.execution` had no projected row for the failed execution
  (count 0), but the event log — the source of truth per
  `execution-model.md` — carries the full terminal sequence.  The
  server stores the `call.error` event with `status=FAILED`; its
  context payload columns were null at the DB layer (server-side ingest
  detail).  The worker-side payload is asserted by the unit test
  `predispatch_terminal_failure_emits_call_error`.

## Manual escalation needed

None.  semantic-release will tag `v5.15.1` + publish the worker crate
asynchronously from the merge to `main` (the ai-meta pointer already
references the correct merge commit `99e2c66`).
