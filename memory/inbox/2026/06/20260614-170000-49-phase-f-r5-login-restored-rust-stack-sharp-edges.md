# #49 Phase F R5 — production login RESTORED + two Rust-stack playbook sharp-edges

**Date:** 2026-06-14
**Issue:** noetl/ai-meta#49 (stays OPEN; Python still at 0/0 for rollback)
**Resolution comment:** https://github.com/noetl/ai-meta/issues/49#issuecomment-4702544902

## What was asked
Restore production gateway login (broken since the Phase F R5 Rust-stack
cutover). Standing guidance: "don't use old python convention — move forward
with rust playbooks when needed." Fix-forward (user declined rollback 3×).

## Outcome: login works end-to-end
Browser Auth0 login at `https://mestumre.dev/login` authenticates and
redirects to the authenticated `/catalog` dashboard; the `auth0_login`
playbook runs to `playbook.completed` across all steps. Verified in-browser
via Playwright.

## What landed
- **worker#81** (worker@9ce4d6d, released v5.20.1) — `SOURCE_FIELD_MAP` maps
  `nats_url`/`nats_user`/`nats_password` credential fields → flat
  `url`/`user`/`password` (mirrors `POSTGRES_FIELD_MAP`). The shipped
  `nats_credential` uses prefixed names; `apply_source_credential` injected
  them verbatim but `NatsConfig` only reads flat names → no `url` →
  `cache_and_callback` NATS kv_put failed → gateway `503 auth backend busy`.
  Prod image rolled to `sha256:61278cb6…f524658` (ops#184).
- **e2e#51** (e2e@1c2a0b5) — migrated `auth0_login.yaml` to Rust conventions
  (prod catalog v102): python `libs:`→`import`; `context.get()`→`input:`+
  `args.get()`; http body `data:`→`json:`; `.context` step-result wrapper
  dropped; session token carried as non-sensitive `sess_ref`; `expires_at::text`.
- **ai-meta@8f787d2** — pointer bump worker@690ef1d + e2e@1c2a0b5 + ops@19d7f84
  + wiki (Home + Sessions-Log).

## Two Rust-engine sharp-edges (durable — will bite other playbook migrations)
1. **Event-log `*token*` redaction destroys inter-step propagation.** Both
   `repos/server/src/sanitize.rs` (`sanitize_sensitive_data`) and
   `repos/worker/src/scrub.rs` redact any field whose key *contains* a
   sensitive term (`token`, `secret`, `password`, `auth`, …) to `[REDACTED]`
   **at event-log storage time**. The orchestrator rebuilds the next step's
   context from the event log → a playbook-generated `session_token` is
   `[REDACTED]` before downstream steps read it. Workaround: carry under a
   non-sensitive key (`sess_ref`); name the field `session_token` only on the
   outgoing boundary (rendered + sent before the redacted call.done).
   Architecturally `data-access-boundary.md` favors response-boundary redaction
   over storage-time — not changed here (security-model decision).
2. **postgres `timestamptz` → null.** `pg_value_to_json`
   (`repos/tools/src/tools/postgres.rs:491`) probes a fixed type list and
   falls through to `Null` for timestamptz/NaiveDateTime/uuid/numeric/bytea.
   A `TIMESTAMPTZ NOT NULL` column came back null. Workaround: `::text` cast.
   Real fix tracked in **noetl/ai-meta#95**.

## Still open (next)
- **System worker pool** — user hint "system pool have to be created." NOT
  required for login (runs on shared pool). Separate follow-up: deploy
  `noetl-worker-system-pool` (consumer `noetl_worker_pool_system`, filter
  `noetl.commands.system.>`) + register system playbooks (outbox publisher,
  projector, scheduled cleanup). 0 system playbooks in prod today.
- **#95** — postgres temporal/uuid/numeric serialization gap.
- Eventually: delete Python deployments after soak; close #49.
