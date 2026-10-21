---
spec: 2026-10-21-gateway-auth-providers
status: draft
created: 2026-10-21T05:30:00Z
owner: claude (for kadyapam)
---

# Gateway auth providers: pluggable sign-in playbooks, gateway-minted sessions

## Problem

The gateway can only sign someone in with an Auth0 ID token
(`POST /api/auth/login`; the server checks the token against the one trusted
tenant, `NOETL_AUTH0_DOMAIN`). Any other way of proving who someone is
(an emailed one-time code, Google or Apple directly, another IdP) has no
place to plug in:

- No route accepts anything but an Auth0 token, and the issuer is
  hard-coded (`https://<NOETL_AUTH0_DOMAIN>/`).
- A playbook that verifies a person itself can't turn that into a session.
  The only workaround is a playbook writing `auth.users` / `auth.sessions`
  rows and returning the session token as its result. That puts a live
  credential in the execution history, and couples a tenant playbook to
  the platform's auth tables.
- Every signed-in user gets the same global `GATEWAY_USER_PLAYBOOKS`. An
  account created on one site (a B&B guest) could run another app's user
  playbooks (travel).

The first consumer is mountshastaranch.com. It wants guest accounts with
its own sign-in page (Google, Apple, a 6-digit code by email; no Auth0
hosted page), with the browser holding no secrets and all verification
done in playbooks.

## Goals

- **Providers are configuration.** An operator maps a provider name to an
  auth playbook (catalog path). Auth0 is one provider; email codes,
  Google, Apple and future IdPs are others. Nothing provider-specific in
  gateway code.
- **Playbooks verify, the gateway mints.** An auth playbook proves who the
  caller is and returns only a verified identity. The gateway turns that
  identity into a session and returns the session token in the HTTP
  response. Session tokens never appear in a playbook's result, so never
  in execution history.
- **Multi-step flows.** A provider can have several actions (e.g. email:
  `start` sends a code, `verify` checks it; Google: `callback` exchanges an
  authorization code). Intermediate steps return a pending status and a
  message for the user.
- **Sessions are validated and authorized the same way for every
  provider.** One session store and cache, one role model.
- **Per-app authorization.** A provider belongs to an app; a session
  carries that app; the user playbook allowlist can be set per app, so a
  ranch guest account can't run travel's playbooks.
- **Existing Auth0 login keeps working unchanged** (travel, the ranch
  admin page), and can later be re-expressed as a provider.

## Non-Goals

- No account linking UI. Same-email identities from different providers
  are separate users unless an Open Question below decides otherwise.
- No passwords. No SMS in this change (cost, 10DLC registration, SMS
  pumping); a provider playbook could add it later.
- No MFA, no device management.
- No change to guest sessions (`ng1.` tokens) beyond letting the auth
  routes be called without any session.

## Constraints

- Execution model: the gateway authenticates, authorizes and forwards. It
  doesn't touch a database itself. Identity checks (codes, OAuth
  exchanges, JWKS) run in provider playbooks. Users and sessions are
  persisted by the control plane (server), as the sync login path does
  today.
- No secrets in the browser, the gateway config or the playbook result.
  Provider secrets (Google client secret, Apple signing key, email API key,
  the OTP hashing key) live in the NoETL keychain / Secret Manager and are
  used only inside playbook steps.
- Inputs to auth playbooks (codes, OAuth authorization codes) do land in
  the event log. They are single-use and short-lived. Results must never
  contain a reusable credential (enforced: the gateway rejects a result
  that has any field outside the result contract).
- Rate limits for the auth routes in the gateway, per client IP and per
  provider-declared key (e.g. the email address), reusing the guest
  limiter. In-process per pod, like guest limits.
- Validate on kind before GKE (`agents/rules/deployment-validation.md`).
  Note the kind stack's refs-in-state result shape (step results over a few
  KB arrive as `{_ref,_store,data}`); the auth playbooks' results are small.

## Design

### Configuration

| Env | Meaning |
|---|---|
| `GATEWAY_AUTH_PROVIDERS` | JSON. `{ "<provider>": { "playbook": "<catalog path>", "actions": ["start","verify"], "app": "<app>", "session_hours": 720, "limits": {...} } }`. Unset = no provider routes (today's behaviour). |
| `GATEWAY_APP_USER_PLAYBOOKS` | JSON `{ "<app>": ["<catalog path>", ...] }`. A session of app X may run these (plus guest-allowlisted ones). Sessions without an app (today's Auth0 logins) keep using `GATEWAY_USER_PLAYBOOKS`. |

Example for the ranch:

```json
{
  "msr-email":  { "playbook": "shastaranch/auth/email_code", "actions": ["start", "verify"], "app": "mountshastaranch", "session_hours": 720 },
  "msr-google": { "playbook": "shastaranch/auth/google",     "actions": ["callback"],        "app": "mountshastaranch", "session_hours": 720 },
  "msr-apple":  { "playbook": "shastaranch/auth/apple",      "actions": ["callback"],        "app": "mountshastaranch", "session_hours": 720 }
}
```

### Flow

1. `POST /api/auth/providers/{provider}/{action}` (public; only providers
   in config, only their declared actions; body ≤ 4 KB JSON).
2. The gateway checks rate limits (per IP; per `limit_key`, see below) and
   runs the provider playbook **as the gateway's system identity** (not as
   the caller), with workload `{action, input: <body>, client_ip,
   user_agent, request_id}`. It waits for the result through the existing
   internal callback (`/api/internal/callback`, request id registered by
   the gateway, as login does today) with a timeout.
3. The playbook returns one of (contract: `auth-provider-result.schema.json`):
   - `{status: "pending", message, data?, limit_key?}`: e.g. "We emailed a
     code". `data` is a small map passed to the client (no secrets);
     `limit_key` (e.g. a hash of the email address) lets the gateway rate-
     limit per identifier.
   - `{status: "authenticated", identity: {subject, email?,
     email_verified?, name?, picture?}}`: `subject` is the provider's
     stable id for the person (Google `sub`, Apple `sub`, a hash of the
     verified email address for email codes).
   - `{status: "denied", message}`.
4. On `authenticated` the gateway calls the server
   (`POST /api/auth/session`, new, internal, authenticated with the
   gateway's service credential). The server upserts `auth.users` keyed by
   `"<provider>|<subject>"` (stored in the existing `auth0_id` column, so
   identity binding (`uid` / `user_uid`) keeps working as `provider|sub`),
   records `app`, creates `auth.sessions` (token, expiry from
   `session_hours`), and returns `{session_token, expires_at, user}`.
5. The gateway caches the session (as login does) and responds
   `{status: "authenticated", session_token, expires_at, user}`. Only this
   HTTP response carries the token.
6. Validation (`auth_middleware`, cache → server validate) is unchanged,
   except that the validated session now includes `app`, and `Policy` uses
   the app's playbook list.
7. `POST /api/auth/logout` (new, generic): deletes the session (server)
   and evicts it from the cache.

### Building blocks for provider playbooks (noetl-tools)

- rhai: `random_digits(n)` and `random_token(bytes)` (OS CSPRNG),
  `hmac_sha256_hex(key, msg)`, `sha256_hex(msg)`, constant-time
  `eq_ct(a, b)`. Today's rhai has none of these, so an email code
  can't be generated or stored hashed.
- http tool: keep `auth:` on pipeline tasks (today
  `task_sequence::build_task_config` drops it).

### First consumer: mountshastaranch.com (site repo, not platform)

- `shastaranch/auth/email_code`: `start` makes a 6-digit code, stores
  `hmac(code)` + expiry (10 min) + attempts (max 5) keyed by the email hash
  in the site's Firestore, and sends the code by email (Resend). `verify`
  checks and deletes it, returns `authenticated` with `subject =
  hmac(lowercased email)`.
- `shastaranch/auth/google` and `apple`: `callback` takes `{code,
  code_verifier, redirect_uri, nonce}` from the site's own `/account/`
  page, exchanges the code at the provider's token endpoint with the
  client secret from the keychain, trusts the ID token received over TLS
  from that endpoint, checks `aud` and `nonce`, returns the identity.
- The site's `/account/` page (already built on branch
  `feat/guest-signin` in the site repo) calls only the gateway.

## Acceptance Criteria

- [ ] With `GATEWAY_AUTH_PROVIDERS` unset, `/api/auth/providers/*` is 404
      and every existing route behaves as before (test suite green).
- [ ] An unknown provider or an undeclared action is 404; a body over
      4 KB is 413.
- [ ] A provider playbook returning `pending` yields 200 with `status`,
      `message` and `data` only; returning `denied` yields 401 with the
      message; a result with any field outside the contract, or a
      timeout, yields 502 and no session.
- [ ] A provider playbook returning `authenticated` yields 200 with a
      session token that works on `/graphql` and `/events`, and the
      playbook's own result in execution history contains no session
      token.
- [ ] The user row is keyed `provider|subject`; a second sign-in with the
      same subject reuses it; `uid`/`user_uid` binding uses that key.
- [ ] A session of app A can execute A's `GATEWAY_APP_USER_PLAYBOOKS` and
      gets 403 for a playbook only on `GATEWAY_USER_PLAYBOOKS` or app B's
      list; an Auth0 session without an app is unaffected.
- [ ] `POST /api/auth/logout` makes the token fail on the next request
      (cache evicted).
- [ ] Per-IP and per-`limit_key` limits return 429 with `Retry-After`.
- [ ] rhai `random_digits`, `random_token`, `hmac_sha256_hex`,
      `sha256_hex`, `eq_ct` exist with unit tests; pipeline http tasks
      keep `auth:` (unit test).
- [ ] Validated on kind with a test provider playbook (pending → verify →
      session → execute an app playbook → logout), against locally built
      gateway, server and worker images.
- [ ] Gateway wiki page for auth providers added with the code.

## Plan / Task Breakdown

1. noetl-tools: rhai crypto/random functions; keep `auth:` on pipeline
   tasks. Release; bump the worker pin.
2. Server: `POST /api/auth/session` (internal; upsert user by
   `provider|subject`, app, session with expiry), `POST /api/auth/logout`,
   `app` in validate output. Migration: `auth.users.app` (nullable),
   `auth.sessions.app` (nullable).
3. Gateway: config parsing + validation; provider route; system-identity
   execution with internal callback; result contract check; session mint
   via server; cache; `app` on `UserContext`; `Policy` per-app allowlist;
   logout route; limiter reuse; tests; wiki page.
4. Kind validation (test provider playbook in `e2e/fixtures`).
5. PRs to noetl/tools, noetl/server, noetl/gateway; releases; ops manifests
   (env for the ranch providers); prod rollout with the user's OK.
6. Site (mountshastaranch): provider playbooks, keychain entries, `/account/`
   page switched to the gateway routes.

## Open Questions

- [ ] Same email from two providers (Google and email code): separate
      users (proposed), or one user keyed by verified email?
- [ ] Session lifetime for ranch guests: 30 days (proposed) or shorter?
- [ ] Where the email-code state lives: the site's Firestore (proposed,
      tenant data stays in the tenant's store) or a platform table?
- [ ] Should the existing Auth0 login become an `auth0` provider in this
      change, or later (proposed: later; keep `/api/auth/login` as is)?
- [ ] Admins: should a provider-created user ever get the `admin` role, or
      only Auth0 users (proposed: roles stay manual in `auth.user_roles`,
      for any user)?

## Verification Plan

- Unit and route tests in gateway, server and tools for each criterion.
- Kind run of the full flow with a fixture provider playbook, including
  the 404/413/429/502/403 cases, and a check that no execution result in
  the event log contains the minted token.
- Ranch site: sign in by email code, Google and Apple on a Pages preview
  pointed at a test gateway or on prod after rollout; chat turn runs as
  the user (`user_uid = provider|sub`), a travel playbook is refused.

## Linked Issues

- (filled in by `spec-to-tasks`)
