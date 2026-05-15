# Travel gateway NoETL API polling fix shipped

Date: 2026-05-13 23:19 PDT

After the callback-timeout fallback shipped, the browser progressed to execution
polling but surfaced `Request failed with status code 404`. The root cause was a
gateway route split in the Travel frontend: Auth endpoints live under
`/api`, but NoETL execution detail and cancel endpoints live under `/noetl` when
the app is authenticated through the gateway. Travel was polling
`https://gateway.mestumre.dev/api/executions/{id}`, which correctly returns 404.

Fix shipped in `repos/travel` PR #36:

- Add a NoETL API base resolver that uses `https://gateway.mestumre.dev/noetl`
  when a gateway session token is present.
- Route `getExecution(id)` through that NoETL API base.
- Route best-effort `cancelExecution(id)` through the same NoETL API base.
- Leave login, validate, check-access, GraphQL, and SSE on their existing gateway
  auth/control-plane routes.

Validation:

- `npm run build` passed locally in `repos/travel`.
- `npm test -- --run` passed locally: 9 files, 19 tests.
- GitHub `Build and verify` passed on PR #36.
- Cloudflare Pages preview passed on PR #36.
- PR #36 was squash-merged to `noetl/travel@941af48`.
- Main Cloudflare Pages deploy passed for run `25845182066`.
- Live `https://travel.mestumre.dev` serves asset `index-Bruwa1s2.js`, and the
  deployed JavaScript includes the `/noetl` execution API base.

Design lesson:

Gateway-integrated SPAs must keep the route split explicit: authentication and
control-plane routes use `/api`; proxied NoETL runtime endpoints use `/noetl`.
Copying the auth base URL into execution polling makes callback fallback fail
with a misleading 404.
