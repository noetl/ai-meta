# R-2.3 Phase C2 complete — Flight TLS + bearer + mTLS trust boundary landed
- Timestamp: 2026-06-01T20:12:41Z
- Author: Kadyapam
- Tags: phase-c2,flight,tls,mtls,bearer-auth,trust-boundary,r-2-3,closed

## Summary
The R-2.3 Phase C2 trust-boundary work shipped across 10 PRs in
6 sub-phases.  Closes noetl/ai-meta#33.

## Sub-phases + PRs

| Sub | What | PRs (merged) | noetl release |
|---|---|---|---|
| C2.1 | Server TLS — NoetlFlightServer.from_env reads NOETL_FLIGHT_TLS_CERT/_KEY; partial-pair fail-fast; location auto-upgrades grpc:// → grpc+tls:// | noetl/noetl#646 | 4.3.0 |
| C2.2 | Rust client TLS — FlightTlsConfig::new().ca_certificate().domain_name() + FlightResolver::connect_with_tls | noetl/cli#45 | noetl-arrow-flight-client 0.3.0 |
| C2.3 | Bearer-token middleware — Python BearerTokenMiddlewareFactory (server, NOETL_FLIGHT_BEARER_TOKENS, rotation set); Rust FlightAuth::bearer + FlightConfig + connect_with; result_fetch.bearer_token (keychain alias or literal) | noetl/noetl#647, noetl/cli#46, noetl/tools#10 | noetl 4.4.0, 0.4.0, noetl-tools 2.13.0 |
| C2.4 | mTLS client identity — NOETL_FLIGHT_CLIENT_CA + verify_client=True on server; FlightTlsConfig::identity on client; result_fetch.client_cert_path + client_key_path | noetl/noetl#648, noetl/cli#47, noetl/tools#11 | noetl 4.5.0, 0.5.0, noetl-tools 2.14.0 |
| C2.5 + C2.6 | Cert + Secret + deployment bootstrap (openssl-based generate-flight-tls.sh) + kind validation rig (flight-tls-validation.{yaml,sh,sql}) | noetl/ops#132 | n/a |

## Trust-boundary surface (operator-facing)

### Server env vars
- `NOETL_FLIGHT_TLS_CERT` + `NOETL_FLIGHT_TLS_KEY` — PEM pair.
  Partial → ValueError fail-fast.  Location auto-upgrades to
  `grpc+tls://`.
- `NOETL_FLIGHT_BEARER_TOKENS` — comma-separated rotation set.
  Empty → no auth.
- `NOETL_FLIGHT_CLIENT_CA` — PEM bundle.  Requires server TLS;
  partial → ValueError fail-fast.
- Startup log: `tls=plaintext|tls|mtls auth=none|bearer(N)`.

### Rust client API
- `FlightTlsConfig::new().ca_certificate(pem).identity(cert,key).domain_name(host)`
- `FlightAuth::bearer(token)`
- `FlightConfig::new().tls(tls).auth(auth)`
- `FlightResolver::connect_with(endpoint, config)` — threads into
  `tonic::transport::Endpoint::tls_config()` + per-request
  `authorization: Bearer <token>` metadata header.

### Playbook surface (result_fetch tool kind)
- `tls_ca_path` — filesystem path to server CA (worker pod, k8s
  Secret).
- `client_cert_path` + `client_key_path` — filesystem paths to
  worker client identity.  Partial → FlightFetchError::Transport
  at build_flight_config time.
- `bearer_token` — NoETL keychain credential alias (preferred per
  agents/rules/execution-model.md) or literal token.  Resolved
  via ctx.get_secret(value).

### Operational rig (noetl/ops)
- automation/development/generate-flight-tls.sh — openssl-based
  CA + server cert + client cert + bearer token generator.
  Creates 3 k8s Secrets + strategic-merge patches deployments.
  --off reverts.  Idempotent re-run rotates.  Generated certs
  never land in repo.
- automation/development/flight-tls-validation.{yaml,sh,sql} —
  kind validation rig.  Pin Rust worker, bootstrap auth,
  register+execute, probe, EXIT-trap teardown.

## Boundary discipline (per execution-model.md)

- Server cert/key + accepted-token list + client CA → platform
  credentials → k8s Secret / env-var paths.
- Worker client cert+key+bearer-token → business-logic
  credentials → keychain alias (bearer) + filesystem path
  (cert/key, since tonic's TLS handshake consumes raw PEM bytes).
- Literal credential bytes NEVER in playbook config or this repo.

## Cross-runtime parity finding (mid-session)

In passing while building Phase C2, found two underlying issues
that the validation rig surfaced + got fixed:

- noetl/tools#9 — template `.result` accessor proxy added to the
  Rust template engine (StepResultProxy minijinja Object impl).
  Python's render.py has had this fall-through for ages; the
  Rust worker rendered the same playbook fragment as `undefined
  value`.  Cross-runtime parity now.
- noetl/tools#9 (same PR) — derive_flight_endpoint emits
  http://...:8083 instead of grpc://...:8083.  Tonic's
  Endpoint::from_shared only accepts http/https; the grpc://
  scheme that Java + pyarrow Flight clients accept surfaces as
  `Bad :scheme header` at request time.

## What's NOT included

- Manual kind run of validate-flight-tls.sh against the merged
  images (operator's call per deployment-validation.md; rig is
  idempotent + auto-cleans).
- Production cert-manager path (Secret shape is identical so the
  openssl→cert-manager swap is drop-in; cert-manager config not
  shipped here).
- Multi-endpoint FlightInfo for sharded result tiers (future
  ai-task).
- Observability spans on the auth path (future ai-task).

## Pointer-bump trail (ai-meta main)

66f8214 (noetl C2.1), 9aaaa56 (cli C2.2), eb88529/f6351e0/9cda164
(C2.3 server/client/tool), 503df24/1326c79/38d4f8e (C2.4
server/client/tool), 5729bc5 (ops C2.5+C2.6).  Each paired with
the corresponding wiki bump (see commit bodies for cross-refs).

## Actions
-

## Repos
-

## Related
-
