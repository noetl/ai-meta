---
paths:
  - "repos/noetl/**"
  - "repos/server/**"
  - "repos/worker/**"
  - "repos/tools/**"
  - "repos/cli/**"
  - "repos/e2e/**"
  - "repos/ops/**"
---

# No Default Connection

Every playbook step that touches a database, external API, or
any credentialed resource MUST declare its credential alias
explicitly. No fallback. No default. No implicit connection.

## The rule

**There is no default database connection in NoETL.**

A playbook step that uses `tool: postgres`, `tool: snowflake`,
`tool: http` (with auth), `tool: duckdb` (with remote catalog),
or any tool kind that requires credentials MUST include an
explicit `credential:` or `auth:` field referencing a registered
credential alias.

```yaml
# CORRECT — explicit credential alias
- step: query_users
  tool: postgres
  credential: "pg_k8s"
  input:
    query: "SELECT * FROM users LIMIT 10"

# WRONG — no credential, relies on some ambient default
- step: query_users
  tool: postgres
  input:
    query: "SELECT * FROM users LIMIT 10"
```

If a step omits the credential reference, the worker MUST
reject it with a clear error rather than falling back to any
environment-level default, hardcoded DSN, or ambient connection
pool.

## Why

Three reasons, in order of weight:

### 1. Credential isolation prevents cross-tenant leaks

NoETL is multi-tenant by design. If a worker falls back to a
"default" Postgres connection when a playbook doesn't specify
one, a tenant's playbook could accidentally read from (or write
to) another tenant's database — or worse, the platform's own
`noetl.*` tables. An explicit alias forces the playbook author
to name the target, and the credential store enforces that the
alias resolves to the right endpoint.

### 2. E2E testability requires known state

The e2e fixture suite runs playbooks against a kind cluster.
When playbooks rely on an implicit default connection, failures
are opaque: "null pg config", "connection refused", or silent
misrouting to the wrong database. Explicit credential aliases
make every fixture's dependencies visible in the YAML —
reviewers and CI can verify that the alias exists in the test
credential set before running.

### 3. Audit trail and credential rotation

The keychain tracks which credential alias was used for each
execution. If a step uses an ambient default, the audit log
shows no credential reference — making it impossible to answer
"which playbook runs used the rotated credential?" after a
rotation event.

## What this covers

- **Playbook YAML** — every step with a credentialed tool kind.
- **E2E fixture YAML** — every test playbook in
  `repos/e2e/fixtures/` or `repos/ops/automation/`.
- **System playbooks** — `system/outbox_publisher`,
  `system/projector`, etc. These use internal API endpoints
  (per [`data-access-boundary.md`](data-access-boundary.md)),
  but when they need credentials for those calls, the alias
  is explicit.

## What this does NOT cover

- **Platform runtime credentials** — the worker's own NATS
  connection, the server's own DATABASE_URL. These are
  infrastructure, not playbook-level, and are configured via
  env vars / K8s Secrets per
  [`execution-model.md`](execution-model.md).
- **Tool kinds that don't need credentials** — `tool: rhai`,
  `tool: shell` (local scripts), `tool: duckdb` (local-only
  in-memory). If the tool kind never touches a remote resource,
  no credential is required.

## Worker enforcement

The Rust worker (`repos/worker/`) and Python worker
(`repos/noetl/`) MUST NOT implement any "default connection"
fallback. The credential resolution path is:

1. Step declares `credential: "<alias>"` or `auth: "<alias>"`.
2. Worker calls `GET /api/credentials/<alias>` on the server.
3. Server returns the decrypted credential data.
4. Worker passes the credential to the tool adapter.
5. If step 1 is missing → worker emits `call.error` with a
   message naming the missing field. No fallback.

If a PR introduces a default-connection fallback path in the
worker's tool dispatch, push back. The fix is in the playbook
YAML, not in the worker code.

## Reviewing playbook fixtures

When reviewing a PR that adds or modifies a playbook fixture:

1. Grep for tool kinds that need credentials:
   `tool: postgres`, `tool: snowflake`, `tool: http` (with
   auth headers), `tool: gcs`, etc.
2. For each match, verify a `credential:` or `auth:` field
   is present on the same step.
3. Verify the alias is in the credential store (check
   `/Users/akuksin/projects/noetl/credentials/` for the
   source files, or query `GET /api/credentials` on the
   running server).

## Coordination with other rules

- [`execution-model.md`](execution-model.md) — the secrets
  and credentials rule says business-logic credentials live in
  the keychain, referenced by alias. This rule is the strict
  enforcement: no alias = no connection.
- [`data-access-boundary.md`](data-access-boundary.md) —
  system workers talk to the server API, not directly to the
  DB. When they need a credential for the API call, the alias
  is explicit.
- [`deployment-validation.md`](deployment-validation.md) —
  kind validation catches missing-credential failures early,
  but only if the fixture declares the alias so the error is
  "credential not found" rather than "null config".

## History

Codified 2026-06-08 after the full e2e sweep on v2.64.0
(Rust server + Rust worker, Python scaled to 0). Several
Tier 3 playbooks (`postgres_test`, `http_to_postgres_simple`)
failed with "null pg config" because they had no `credential:`
block and the worker had no default to fall back to. The
failures were correct behavior — the playbooks were wrong,
not the worker. This rule makes the expectation permanent.
