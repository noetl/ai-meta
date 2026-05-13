# Travel Public Domain Rename

Kadyapam renamed the public trip-planner URL from `muno.mestumre.dev` to
`travel.mestumre.dev`.

Updates landed:

- `noetl/travel#16` merged at `0e2d588`, switching the Cloudflare Pages project
  name/deploy command from `muno` to `travel`.
- The GitHub Actions workflow no longer declares a GitHub Environment; repo-level
  secrets and variables are sufficient.
- Travel docs now reference `https://travel.mestumre.dev` and the Pages project
  `travel`.
- `.env.example` now uses `VITE_AUTH0_AUDIENCE=https://api.travel.mestumre.dev`.
- GitHub secret `VITE_AUTH0_AUDIENCE` was updated to
  `https://api.travel.mestumre.dev`.
- The Google Maps browser key now allows `https://travel.mestumre.dev/*` while
  preserving existing referrers.
- The trip-planner scoping issue now uses `travel.mestumre.dev` for the Round 8
  Auth0/domain references.

Manual follow-up:

- Kadyapam will update the Auth0 application with the new travel domain.
- Add Cloudflare repository secrets `CLOUDFLARE_API_TOKEN` and
  `CLOUDFLARE_ACCOUNT_ID` when ready to let the workflow deploy instead of skip.
- Create/attach the Cloudflare Pages custom domain `travel.mestumre.dev` to the
  Pages project `travel`.
