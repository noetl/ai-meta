---
thread: 2026-06-09-worker-predispatch-call-error
round: 1
from: claude
to: codex
created: 2026-06-10T05:50:00Z
status: open
expects_result_at: round-01-result.md
tracks: noetl/ai-meta#78
wait_phrase: "ship the worker fix"
---

# Fix worker pre-dispatch error propagation — emit terminal `call.error`

> **Predecessor:** dispatched from the orientation thread
> `../2026-06-09-rust-stack-session-snapshot/round-01-prompt.md`
> (Pending-work item 2). User explicitly routed this Rust change to
> Codex, overriding `agents/rules/handoff-routing.md` for this thread.

You are fixing [noetl/ai-meta#78](https://github.com/noetl/ai-meta/issues/78)
in `repos/worker` (the `noetl-worker` binary). When a command fails
**before tool dispatch** — most visibly when keychain credential-alias
resolution fails — the worker logs `Command execution failed` and drops
the error. No `call.error` event reaches the server, so the execution
sits at `command.started` forever and the UI/`noetl status` show it
running indefinitely. Reproduced on the local kind cluster with a
playbook step referencing a non-existent credential alias.

## Background

- Operate in `/Volumes/X10/projects/noetl/ai-meta/repos/worker`
  (submodule of ai-meta; remote `noetl/worker`). Branch off current
  `main` of that submodule.
- **Known local-only state — do not commit or revert:**
  `repos/worker/Cargo.toml` currently has
  `noetl-tools = { path = "../tools" }` instead of `noetl-tools = "3"`.
  This is deliberate (crates.io still at v3.0.0; v3.1.0 publish
  pending). Keep the path dep in your working tree so builds use local
  tools v3.1.0, but **exclude the Cargo.toml dep line (and any
  Cargo.lock churn from it) from the commit you push**. If that proves
  impossible to separate cleanly, stop and report instead of pushing.
- Cluster context for validation: kind cluster `noetl`
  (`kubectl --context kind-noetl`), server API `http://localhost:8082`,
  worker image `localhost/noetl-worker:dev`, platform DB `noetl` in the
  in-cluster postgres (ns `postgres`). Rust CLI:
  `/Volumes/X10/dev/cargo/bin/noetl` (NOT the pyenv python `noetl`).

### The failing path, file by file

1. `src/worker.rs:306-323` — the dispatch loop's spawned task. On
   `executor.execute_with_server_url(...) -> Err(e)` it only does
   `tracing::error!(... "Command execution failed")`. Nothing is
   emitted to the event log.
2. `src/executor/command.rs` — inside `execute_with_server_url`:
   - L297-307 emits `command.started` (this succeeds).
   - L357-362: `super::auth_alias::resolve_auth_alias(...).await?` —
     the `?` early-returns on alias failure, **before** reaching the
     tool-dispatch match whose error arm emits `call.error`
     (L493-507).
   - L379: `serde_json::from_value(tool_config_value)?` — a malformed
     tool config takes the same silent early-return.
3. `src/executor/auth_alias.rs:151-165` — alias lookup inside
   `resolve_single_tool_alias`. Two distinct failure flavours:
   - L156-158 (`fetch_credential_maybe_sealed ... .with_context(...)`):
     transport/HTTP errors talking to the keychain — **retryable**.
   - L159-165 (`.ok_or_else(...)` on `None`): clean server 404,
     "Credential alias '<x>' not found in keychain" — **terminal**.
4. `src/events/emitter.rs:240-251` already has a `call.error` emit
   helper; `command.rs` has `emit_event_via` (L655) used by the
   existing post-dispatch error arm (L493-507). Reuse the existing
   emission shape — match the payload fields the post-dispatch
   `call.error` sends so the server/UI treat both identically.

## Goal / acceptance criteria

- Any pre-dispatch failure inside `execute_with_server_url` that is
  **terminal** (credential alias 404, malformed tool config, any other
  non-transient error) emits a `call.error` event with status FAILED
  for that step, so the execution reaches a terminal FAILED state
  instead of hanging at `command.started`.
- **Retryable** failures (transient keychain HTTP/transport errors)
  must NOT emit a terminal `call.error` on first failure — preserve
  whatever retry semantics the command path has (attempts /
  redelivery). If attempts exhaust, the failure becomes terminal.
  Implement the terminal-vs-retryable distinction explicitly (e.g. an
  error-classification enum or typed error), not by string-matching
  `anyhow` messages at the call site.
- `src/worker.rs:306` error arm: keep the structured log; add a
  last-resort safety net only if the executor can still return `Err`
  without having emitted a terminal event (document the invariant
  either way in a comment).
- Error messages stay grep-able and carry `execution_id`, `step`,
  `command_id` per `agents/rules/observability.md`.
- No secrets in any log/event payload (alias names OK, values never).
- Unit tests cover: alias-404 → terminal classification; transport
  error → retryable classification; pre-dispatch terminal failure
  emits `call.error` (use the existing emitter/control-plane test
  patterns in `src/events/emitter.rs` + `src/client/control_plane.rs`
  tests as the harness reference).

## Phases

### Phase A — orientation + baseline (read-only)

1. `cd /Volumes/X10/projects/noetl/ai-meta && git submodule status repos/worker repos/tools`.
2. `git -C repos/worker status` — confirm the only pre-existing
   modification is the `Cargo.toml` path dep noted above. Record what
   you see.
3. Read the four files/pointers in Background. Read
   `agents/rules/observability.md` and `agents/rules/execution-model.md`
   (callback/event shape).
4. Baseline: `cargo build` + `cargo test` + `cargo clippy --all-targets`
   in `repos/worker`. Record pass/fail fingerprints before changing
   anything.

### Phase B — implement (local edits only)

5. Create branch `fix/predispatch-call-error` in `repos/worker`.
6. Implement per Goal above. Keep the change scoped to error
   classification + emission; no drive-by refactors.
7. `cargo fmt`, `cargo clippy --all-targets -- -D warnings`,
   `cargo build`, `cargo test` — all green.

### Phase C — kind revalidation (local cluster only; no remote writes)

8. Rebuild the worker image and load it into kind (same recipe the
   prior sessions used for `localhost/noetl-worker:dev`; if unsure,
   `repos/ops/automation/development/noetl.yaml` is the reference —
   scope to the worker), then restart the worker deployment:
   `kubectl --context kind-noetl -n noetl rollout restart deploy/noetl-worker-rust`.
9. Negative test: register + execute a playbook step whose
   `credential:`/`auth:` references a non-existent alias (e.g. copy a
   postgres fixture and set `credential: "no_such_alias"`). Execute via
   `POST http://localhost:8082/api/execute {"path": "<catalog path>"}`.
   Confirm the execution reaches FAILED and the event log contains a
   `call.error` for the step (query the `noetl` DB via
   `kubectl -n postgres exec <pgpod> -- psql -U demo -d noetl -c ...`).
10. Positive regression: run `python3 /tmp/e2e_regsweep.py hello_world
    control_flow_workbook postgres_test` (or the nearest equivalents in
    `repos/e2e/fixtures/playbooks/`) against the rebuilt worker — all
    PASS. If `/tmp/e2e_regsweep.py` is gone, run hello_world + one
    postgres playbook manually via the API and `noetl status`.

### Phase D — wiki update (local edit + report; push rides Phase E)

11. Per `agents/rules/wiki-maintenance.md` Rule 2b: update the
    noetl-worker wiki (`repos/noetl-worker-wiki/`) page covering event
    emission / error taxonomy with the new pre-dispatch
    terminal-vs-retryable behaviour. Commit locally in that wiki repo;
    do not push yet.

### Phase E — sub-issue + push + PR

> ***Run only after explicit human go-ahead. Wait phrase: `ship the worker fix`.***

12. Open the Tier-2 sub-issue on noetl/worker per
    `agents/rules/issue-tracking.md`: title
    `Fix worker pre-dispatch error propagation — Round 01`, label
    `ai-task` (create if missing, colour `#fbca04`), body starts
    `Tracks noetl/ai-meta#78`.
13. Push `fix/predispatch-call-error` to `origin` on noetl/worker
    (NOT main). `gh pr create` with body citing
    `Closes noetl/worker#<sub-issue>` and `Refs noetl/ai-meta#78`,
    summarising the fix + kind validation evidence + wiki diff. Do not
    merge.
14. Push the wiki commit from Phase D to the worker wiki remote.
15. Comment on noetl/ai-meta#78 with the PR URL + sub-issue number.

## FINAL REPORT

Always emit this, even on early STOP. Write it as the body of
`round-01-result.md` in this thread directory, with frontmatter:

```yaml
---
thread: 2026-06-09-worker-predispatch-call-error
round: 1
from: codex
to: claude
created: <ISO8601 UTC>
in_reply_to: round-01-prompt.md
status: complete | partial | blocked
---
```

Then one H2 per phase, using exactly the phase names above
(`## Phase A — orientation + baseline` … `## Phase E — sub-issue + push + PR`),
plus:

```markdown
## Issues observed
- anything surprising; include grep-able fingerprints (error strings,
  exit codes, stack frame top lines, SHAs). Do NOT paraphrase.

## Manual escalation needed
- everything you could not complete unattended, with the precise
  command(s) a human should run.
```

If Phase E was not unlocked, its bullet says
`phase E blocked: awaiting "ship the worker fix"` and the status is
still `complete` (a gated skip counts as attempted).

Commit the result file with message
`handoff(result): 2026-06-09-worker-predispatch-call-error round 01`.
The dispatcher (Claude) will review the result and either close the
thread or write `round-02-prompt.md` — do not start round-02 work
yourself.

## Hard rules for this thread

- Never push to `origin/main` on any repo. Never force-push. Never
  merge PRs yourself.
- Respect `AGENTS.md` and everything under `agents/rules/`
  (`observability.md`, `deployment-validation.md`,
  `issue-tracking.md`, `wiki-maintenance.md` apply here).
- This repo and all noetl repos are public: no secrets, tokens, or
  credential values in commits, issues, PR bodies, or this thread.
- Do not touch the Python noetl server; the target is the Rust stack.
- Do not commit the `Cargo.toml` path-dep for noetl-tools (see
  Background). If preconditions fail, stop and report — don't
  improvise around blockers.
