# Supersede — Cloudflare Access Round 9 cancelled, replaced by gateway-session Round 9'

- date: 2026-05-13T07:30:00Z
- tags: trip-planner, travel, security, auth0, gateway, supersede, correction

## What was cancelled

`bridge/inbox/delegated/20260513-070000-cloudflare-access-travel.task.json`
(committed at `8eda1cf`, NOT yet fired in Codex) is **SUPERSEDED** before
firing. The edge-allowlist model was wrong for this project's
architecture.

Why the original plan was wrong:
- Cloudflare Access at the edge is an allowlist gate — anyone on the
  email allowlist can log in via Auth0, but ALL auth state lives at
  Cloudflare's edge.
- This conflicts with how NoETL is architected. The project already
  uses a **gateway-mediated session auth** pattern in `repos/gui`
  (the admin UI behind `mestumre.dev`): Auth0 SPA login → exchange
  Auth0 token at `gateway.mestumre.dev/api/auth/login` → receive a
  NoETL session_token → all playbook execution calls carry that
  session_token to gateway.
- Travel must use the same pattern so a single user identity
  (kadyapam@gmail.com via Auth0) flows through Auth0 → gateway login
  playbook → NoETL session → playbook execution. One identity, one
  session, one audit trail.

What the prior plan got wrong specifically:
- Edge gate didn't introspect identity into the NoETL session model
  at all — the SPA would still hit NoETL endpoints anonymously after
  passing the edge.
- The Cloudflare Access JWT (`CF-Access-Jwt-Assertion`) doesn't slot
  into NoETL's existing auth model; it would require new server-side
  validation work that would never align with the gui auth flow.
- The `cloudflare-access-allow-rule` secret was for an allowlist
  semantics that doesn't apply.

## Decision

- Cancel the Cloudflare Access round before it fires.
- Open a new Round 9' that mirrors `repos/gui`'s gateway-session auth
  flow inside `repos/travel`.
- The Cloudflare API token (`cloudflare-access-token` GCP secret) can
  stay provisioned "just in case" — useful for future Cloudflare API
  work — but is NOT used by Round 9'.
- The `cloudflare-access-allow-rule` GCP secret (if provisioned) is
  no longer needed for any active round. Kadyapam can leave or
  delete; it's harmless.

## What replaces it

New round: `20260513-080000-travel-gateway-session-auth` — implements
the gateway session pattern by inspecting `repos/gui`'s auth flow and
mirroring it in `repos/travel`.

Cancel the original task JSON by referencing it as superseded; leave
the file in place for audit history.

## Pattern to mirror (per Kadyapam's clarification)

```
Cloudflare Pages public SPA (travel.mestumre.dev)
        ↓
Travel app login button
        ↓
Auth0 SPA flow (same user: kadyapam@gmail.com, existing SPA app)
        ↓
POST https://gateway.mestumre.dev/api/auth/login
  (Auth0 access token in body or Authorization header)
        ↓
NoETL Auth0 login playbook validates the token, issues session_token
        ↓
Travel SPA stores session_token (localStorage matches GUI behaviour)
        ↓
All playbook executions go through gateway.mestumre.dev with
session_token. NO direct unauthenticated /api/execute calls.
```

Guest mode on travel.mestumre.dev: **disabled for production builds**.
Keep guest mode available for local dev only (via Vite env flag
`VITE_ALLOW_GUEST=true`).

## Related

- `bridge/inbox/delegated/20260513-070000-cloudflare-access-travel.task.json` (superseded)
- `memory/inbox/2026/05/20260513-070000-handed-cloudflare-access-travel-to-codex.md` (superseded)
- `scripts/cloudflare_access_travel_msg.txt` (superseded — do not paste)
- `bridge/inbox/delegated/20260513-080000-travel-gateway-session-auth.task.json` (the corrected round)
- `repos/gui/` — source of the auth pattern to mirror
- noetl/travel#17 — in-app Auth0 SPA flow (the foundation; extended by Round 9')
