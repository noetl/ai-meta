# Travel mirrors GUI Auth0 hash-token flow

Date: 2026-05-13

Kadyapam confirmed the Travel app still did not reach the gateway auth playbook
after the timeout hotfix. That moved the diagnosis before
`POST /api/auth/login`.

Re-inspection of `repos/gui` showed the actual source pattern:

- `GatewayLogin` builds the Auth0 authorize URL directly.
- The authorize URL uses `response_type=id_token token`.
- The callback reads `id_token` from `window.location.hash`.
- The GUI immediately posts `{ auth0_token, auth0_domain }` to
  `${gatewayBaseUrl}/api/auth/login`.

Travel had incorrectly routed through `@auth0/auth0-react` and
`getIdTokenClaims()`, which could hang before the gateway request was ever
started.

`noetl/travel#21` merged at
`a6207a298fda52623ce83664fdb986f5974ab5c3`:

- `src/auth/MunoAuthProvider.tsx` now builds the Auth0 authorize URL directly,
  parses `id_token` from `/callback#...`, posts it to the gateway, and stores
  the returned gateway session.
- `docs/auth/auth0-setup.md` and `docs/auth/gateway-session-pattern.md` now
  document the URL-hash flow instead of the SDK claim lookup.

Validation:

- `npm run type-check`
- `npm run test`
- `npm run smoke:widgets`
- `npm run build`
- Local browser smoke confirmed sign-in redirects to Auth0 with
  `response_type=id_token token` and `/callback` redirect.
- Cloudflare Pages main deploy run `25807101113`.
- Live asset `/assets/index-JzQNisHu.js` contains the direct hash-token flow.

Next expected live smoke result:

- After Auth0 redirects back to `https://travel.mestumre.dev/callback#...`, the
  gateway auth playbook should start immediately.
- If auth still fails, it should now be visible as a gateway response/error,
  not as a pre-gateway stall.

No credentials or token values were recorded.
