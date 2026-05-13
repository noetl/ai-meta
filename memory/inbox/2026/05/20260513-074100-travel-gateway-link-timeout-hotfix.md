# Travel gateway-link timeout hotfix

Date: 2026-05-13

Travel Round 9 remains AMBER, but the live failure mode is now bounded.
Kadyapam's browser smoke advanced past the Auth0 configuration issue and then
hung indefinitely on `Linking to gateway...`, with no useful console output.

`noetl/travel#20` merged at
`05285bd50f86a45d57ef5f4146599f76b170b28e`:

- `src/api/gatewaySession.ts` now wraps gateway auth login and session
  validation fetches with an `AbortController` timeout of 15 seconds.
- `src/auth/MunoAuthProvider.tsx` now wraps Auth0 ID-token lookup with a
  10-second timeout.
- `src/api/gatewaySession.test.ts` covers a stalled gateway login request.

Validation:

- `npm run type-check`
- `npm run test`
- `npm run smoke:widgets`
- `npm run build`
- Cloudflare Pages main deploy run `25806130152`
- Live bundle `/assets/index-DK_aAEHq.js` contains both timeout messages.

Expected next browser smoke:

1. If the gateway exchange succeeds, the chat shell loads and gateway requests
   carry `Authorization: Bearer <session_token>`.
2. If the bug remains, the UI should show either `Auth0 ID token lookup timed
   out after 10s` or `Gateway auth request timed out after 15s` instead of
   spinning forever. That message becomes the next debugging axis.

No credentials or token values were recorded.
