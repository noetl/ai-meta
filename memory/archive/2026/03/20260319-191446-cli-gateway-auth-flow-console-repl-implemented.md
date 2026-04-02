# CLI gateway auth flow + console REPL implemented
- Timestamp: 2026-03-19T19:14:46Z
- Author: Kadyapam
- Tags: cli,gateway,auth0,console,repl,docs,quantum-playbook

## Summary
Updated repos/cli with a new noetl console REPL command that runs CLI subcommands in-session and shows active context/server/proxy mode in prompt. Context add now behaves as upsert and preserves cached gateway token/auth fields unless explicitly replaced, which helps retrofit existing contexts like gke-prod with Auth0 settings. Updated repos/docs and repos/cli README with gateway Auth0 context/login workflow and console usage. Validation: cargo check passed; console prompt tested; direct distributed register+exec for tests/fixtures/playbooks/quantum_cudaq completed successfully against GKE NoETL API via port-forward. Gateway register attempt returned 401 due expired cached session token, so a fresh Auth0 login callback token is still required to complete live gateway-path execution test.

## Actions
- Added `noetl console` command in `repos/cli` (`src/main.rs`) with connection-aware prompt and command loop.
- Added console helpers: prompt parser, `where` command, gateway/direct mode indicator, and subprocess execution of CLI commands.
- Changed `context add` behavior to update existing contexts without wiping cached gateway session token/auth settings.
- Updated docs in `repos/cli/README.md`, `repos/docs/docs/reference/noetl_cli_usage.md`, and `repos/docs/docs/cli/index.md`.
- Verified direct distributed flow by registering/executing `tests/fixtures/playbooks/quantum_cudaq/quantum_cudaq.yaml` against GKE NoETL API via port-forward.
- Confirmed gateway path currently requires fresh Auth0 login token (cached token returned `401 Invalid or expired session`).

## Repos
- `repos/cli`
- `repos/docs`
- `repos/noetl` (playbook used for validation run only)

## Related
- Gateway URL: `https://gateway.mestumre.dev`
- Target cluster: `gke_noetl-demo-19700101_us-central1_noetl-cluster`
