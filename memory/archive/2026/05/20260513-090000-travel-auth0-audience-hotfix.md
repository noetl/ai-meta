# Travel Auth0 audience hotfix

Date: 2026-05-13

Context:
- `travel.mestumre.dev` redirected back to `/callback#error=access_denied`.
- Auth0 reported `Service not found: https://api.travel.mestumre.dev`.
- That meant the Travel SPA was still sending an Auth0 `audience` parameter for a non-existent API.

Fix:
- `noetl/travel#22` removed Auth0 audience from the authorize URL and stripped stale `VITE_AUTH0_AUDIENCE` plumbing from Pages, Docker, and container build scripts.
- This matches the NoETL GUI gateway-session pattern: request only an Auth0 ID token, then exchange it with `https://gateway.mestumre.dev/api/auth/login`.

Validation:
- `npm run type-check`
- `npm run test`
- `npm run smoke:widgets`
- `npm run build`
- Cloudflare Pages main deploy `25810371735` passed.
- Live bundle at `https://travel.mestumre.dev` was checked and contains no `api.travel` or `audience` string.

Lesson:
- For gateway-mediated Auth0 session exchange, do not configure a frontend API audience unless the Auth0 API exists and the gateway expects an access token. Travel follows GUI: ID-token-only login, gateway session token afterward.
