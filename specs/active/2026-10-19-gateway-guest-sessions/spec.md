---
spec: 2026-10-19-gateway-guest-sessions
status: approved
created: 2026-10-20T02:31:32Z
owner: claude (for kadyapam)
---

# Gateway guest sessions for allowlisted public playbooks

## Problem

Every gateway route that starts or reads a playbook run requires a
session minted from an Auth0 login (`auth/middleware.rs:95-125`). A public
website that wants to offer an AI assistant to signed-out visitors cannot
do it through the gateway today:

- `/graphql`, `/noetl/{*path}` and the scoped-app routes sit behind
  `auth_middleware`; `/events` validates `session_token` against the KV
  session cache only (`sse.rs:88-114`).
- Execution ownership ignores `user_id <= 0`
  (`authorization.rs:179-206`), so even a synthetic identity could not
  poll its own run.
- Travel's `VITE_ALLOW_GUEST` bypasses the gateway and only works in local
  development; ingress listeners have no result channel, and a bearer
  secret in a browser would be public; scoped apps require a session.

The first consumer is a public website concierge whose playbook is already
on the prod `GATEWAY_USER_PLAYBOOKS` list. It currently forces visitors to
sign in before asking anything, which most of them won't do.

## Goals

- A visitor with no account gets a short-lived **guest session** from the
  gateway and can run only the playbooks an operator allowlisted for
  guests, then read the result over SSE or by polling, exactly like a
  signed-in user.
- Off by default: a gateway with no guest configuration behaves exactly
  as today.
- Abuse is bounded inside the gateway: per-guest and per-client-IP rate
  limits on minting guest sessions and on guest executions.
- Generic: nothing site-specific in gateway code; the allowlist and
  limits are configuration.

## Non-Goals

- No anonymous access to anything else: no catalog, credentials, admin,
  other users' executions, cancel of others' runs, scoped apps or ingress.
- No change to Auth0 login, signed-in sessions or the server's auth API.
- No persistent guest accounts, no guest rows in Postgres.
- No CAPTCHA / bot detection in this change (edge rules can be layered on
  later).
- No change to scoped-apps mode: when scoped apps are enabled, guest
  routes are not mounted.

## Constraints

- Execution model: the gateway stays a gatekeeper. It only authenticates,
  authorizes and forwards; it touches no database for guests (the guest
  token is self-verifying, see Plan). Playbooks do all data work.
- No secrets in the browser. The guest token is an opaque bearer issued by
  the gateway; the signing key lives only in gateway config (Secret
  Manager in prod).
- Guests have no `auth0_sub`, so `bind_identity` keeps failing closed for a
  non-null `uid`/`user_uid` and leaves an explicit `null` anonymous.
  Guests can never act as a user.
- Rate-limit state is in-process per gateway pod (no new store). With N
  replicas the effective limit is up to N×; documented, acceptable for the
  first consumer (single replica in prod).
- Client IP comes from a configured trusted header (e.g.
  `CF-Connecting-IP` or `X-Forwarded-For` first hop) or the socket peer;
  never from an arbitrary client header unless configured. Where the
  origin also accepts direct traffic (prod: a GKE L4 load balancer behind
  a Cloudflare-proxied hostname), that header can be forged, so a
  **global** guest-run ceiling bounds total cost regardless of IP.
- Validate on kind before GKE (`agents/rules/deployment-validation.md`).

## Design

Configuration (all optional; guest mode is on only when both of the first
two are set):

| Env | Meaning |
|---|---|
| `GATEWAY_GUEST_PLAYBOOKS` | CSV of catalog paths guests may execute. Empty/unset = guest mode off. |
| `GATEWAY_GUEST_TOKEN_KEY` | HMAC-SHA256 key, ≥ 32 bytes. Missing/short with playbooks set = startup error. |
| `GATEWAY_GUEST_TTL_SECS` | Guest session lifetime, default 3600. |
| `GATEWAY_GUEST_RUNS_PER_HOUR` | Executions per guest per rolling hour, default 20. |
| `GATEWAY_GUEST_IP_RUNS_PER_HOUR` | Guest executions per client IP per rolling hour, default 60. |
| `GATEWAY_GUEST_IP_SESSIONS_PER_HOUR` | Guest sessions minted per client IP per hour, default 20. |
| `GATEWAY_GUEST_TOTAL_RUNS_PER_HOUR` | Ceiling on all guest executions per rolling hour (per pod), default 600. |
| `GATEWAY_CLIENT_IP_HEADER` | Trusted header carrying the client IP; unset = socket peer. |

Flow:

1. `POST /api/auth/guest` (public, mounted only in guest mode) → per-IP
   mint limit → returns `{session_token, expires_at, guest_id}`. The token
   is `ng1.<base64url(payload)>.<base64url(hmac)>`, payload
   `{gid: <uuid v4>, exp: <unix secs>}`. Nothing is stored.
2. `auth_middleware`: a bearer starting with `ng1.` is verified locally
   (constant-time HMAC compare, `exp` in the future) and becomes a
   `UserContext` with `user_id = 0`, `email = ""`, `auth0_sub = None`,
   `roles = ["guest"]` and a new `guest_id: Option<String>`. It never
   reaches the session cache or the NoETL auth API.
3. `Policy`: the `guest` role may execute only `GATEWAY_GUEST_PLAYBOOKS`
   (kind `playbook`), subject to the per-guest and per-IP run limits
   (429 with `Retry-After` when exceeded); proxy access is only `GET
   executions/{id}` and `POST executions/{id}/cancel` for runs it owns.
4. Ownership: `ExecutionOwners` gains an owner key; signed-in owners stay
   keyed by `user_id`, guests by `guest:<gid>`. Existing records are
   unaffected.
5. `/events?session_token=ng1...` verifies the guest token the same way
   and attaches the stream to the caller's `client_id`.
6. Logging: guest mints and 429s at DEBUG with sampling; one INFO line per
   guest execution (path, gid prefix, execution id), no IPs at INFO.

## Acceptance Criteria

- [ ] With no guest env set, `POST /api/auth/guest` is 404 and every
      existing route behaves as before (existing test suite green).
- [ ] With guest env set, `POST /api/auth/guest` returns a token that lets
      `executePlaybook` run an allowlisted playbook and returns an
      execution id.
- [ ] A guest token is rejected (401) when expired, when its HMAC is
      altered, or when it was signed with a different key.
- [ ] A guest cannot execute a playbook outside `GATEWAY_GUEST_PLAYBOOKS`
      (403), even if it is on `GATEWAY_USER_PLAYBOOKS`.
- [ ] A guest can `GET /noetl/executions/{id}` for its own run and gets
      404 for another guest's or a user's run; it gets 403/404 on every
      other `/noetl/*` path.
- [ ] A guest receives its run's `playbook/result` over `/events`.
- [ ] A guest passing a non-null `uid`/`user_uid` is refused (identity
      fail-closed); an explicit `null` is accepted.
- [ ] The 21st guest execution within an hour from one guest, the 61st
      from one IP, and the 21st mint from one IP get 429 with
      `Retry-After`; once the global ceiling is reached, every guest
      execution gets 429 until the window frees.
- [ ] Scoped-apps mode never mounts the guest route.
- [ ] Validated on kind: guest mint → execute → SSE result and poll, plus
      the limit and rejection cases, against the locally built image.
- [ ] Gateway wiki/docs page for guest sessions added with the code.

## Plan / Task Breakdown

1. Gateway (`noetl/gateway`, branch `feat/guest-sessions`):
   config parsing + startup validation; `guest.rs` (token mint/verify,
   limiter); public route; middleware branch; `Policy` guest role;
   owner keys; `/events` guest verification; unit + route tests; docs page.
2. Kind validation with the ops kind recipe and a guest-allowlisted test
   playbook.
3. PR to `noetl/gateway`, review, merge, semantic release.
4. Prod rollout (operator go-ahead): create the signing key in Secret
   Manager, set guest env on the prod gateway deployment, roll the image;
   ops manifest updated in `noetl/ops`.
5. Consumer (outside ai-meta, private): the site playbook accepts a
   missing email and logs guests anonymously; the site chat obtains a
   guest session instead of an Auth0 login.
6. Pointer bump in ai-meta for gateway (and ops) with wiki check.

## Open Questions

- [x] Limits: 20 runs/guest/hour, 60 runs/IP/hour (decided 2026-10-19 by
      the operator); mints/IP/hour default 20.
- [x] Token storage: stateless HMAC token, no KV writes (keeps the gateway
      free of new state; revocation = key rotation).
- [x] Guests and identity: no `auth0_sub`; non-null `uid` fails closed.

## Verification Plan

- Unit tests: token round-trip, tamper, expiry, wrong key; limiter
  windows; `Policy` guest allow/deny; owner-key isolation.
- Route tests (existing `*_routes_tests.rs` style): the acceptance bullets
  for 404-when-off, mint, execute, foreign execution, non-allowlisted
  playbook, identity, 429.
- Kind: curl script for mint → executePlaybook → `/events` result → poll,
  plus tamper/expired/limit cases; results pasted into the umbrella issue.
- Prod: after rollout, one guest turn from the consumer site and a 429
  check, recorded on the umbrella issue.

## Linked Issues

- Umbrella: noetl/ai-meta#484
