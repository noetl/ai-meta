# Travel gateway-session auth AMBER pending browser smoke

- date: 2026-05-13T07:39:03Z
- tags: travel, muno, auth0, gateway-session, cloudflare-pages, amber, browser-smoke

Corrected Round 9 landed the NoETL GUI gateway-session auth model in
`noetl/travel`, superseding the cancelled Cloudflare Access plan. Travel now
uses the Auth0 ID token (`getIdTokenClaims().__raw`) for the gateway exchange,
not the API access token. The request shape mirrors GUI:
`POST https://gateway.mestumre.dev/api/auth/login` with
`{ auth0_token, auth0_domain }`, storing returned `session_token` and
`user_info` in localStorage, and sending `Authorization: Bearer <session_token>`
on gateway execution calls.

Merged PRs:

- `noetl/travel#18` at `4daafae2393fab2f4eef4a548e4201b05fe7a0e6`
- `noetl/travel#19` at `09694e2083c2e3d2ccb1871791ef2e02544af7ae`
- `noetl/docs#69` at `296aeb2521aec32dd40adcd93aa4a987ab40ea9b`

Validation:

- `npm run type-check` passed in `repos/travel`
- `npm run test` passed in `repos/travel` (4 files / 7 tests)
- `npm run smoke:widgets` passed in `repos/travel` for 24 envelopes
- `npm run build` passed in `repos/travel`
- `npm run build` passed in `repos/docs`
- Cloudflare Pages main deploy run `25785214311` passed
- Cloudflare Pages hotfix deploy run `25786167198` passed
- live bundle contains `/api/auth/login`, `session_token`,
  `Linking to gateway`, and `Sign in to start planning`
- hotfix live bundle also contains the GUI Auth0 SPA fallback
  `mestumre-development.us.auth0.com` and public client id, so the sign-in pane
  should no longer be disabled by missing Pages env values

Status is AMBER pending Kadyapam browser smoke:

1. Open `https://travel.mestumre.dev/` in incognito.
2. Confirm sign-in pane appears with no chat shell and no Guest mode path.
3. Complete Auth0 login as the allowed user.
4. Confirm `Linking to gateway...` appears briefly and then the chat shell loads.
5. Start a trip and confirm gateway requests carry
   `Authorization: Bearer <session_token>`.

Result file:
`bridge/outbox/20260513-080000-travel-gateway-session-auth.result.json`.
