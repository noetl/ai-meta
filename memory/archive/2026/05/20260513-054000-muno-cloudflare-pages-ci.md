# Muno Cloudflare Pages CI

Muno now follows the Cloudflare Pages frontend-hosting pattern rather than a
GKE UI deployment.

What landed:

- `noetl/muno#14` merged at `c2191cc8b7d273a7de30a72dac76cfdeaad7ce34`.
- Added `.github/workflows/cloudflare-pages.yml`.
- Added Team4-style `wrangler.toml` with `name = "muno"` and
  `pages_build_output_dir = "dist"`.
- Added npm scripts:
  - `build:cf`
  - `deploy:cf`
- Updated deployment docs to make Cloudflare Pages canonical for
  `muno.mestumre.dev`.

GitHub repository configuration completed by Codex:

- Secret `VITE_AUTH0_DOMAIN` set from GCP Secret Manager `auth0_client`.
- Secret `VITE_AUTH0_CLIENT_ID` set from GCP Secret Manager `auth0_client`.
- Secret `VITE_AUTH0_AUDIENCE` set from GCP Secret Manager `auth0_client`.
- Secret `VITE_GOOGLE_MAPS_KEY` set from GCP Secret Manager
  `google-maps-widget-key`.
- Variable `VITE_NOETL_API_BASE_URL=https://gateway.mestumre.dev/api`.

Manual items still required from Kadyapam:

- Rotate the Cloudflare token pasted into chat before using it.
- Add GitHub secret `CLOUDFLARE_API_TOKEN`.
- Add GitHub secret `CLOUDFLARE_ACCOUNT_ID`.
- Ensure Cloudflare Pages project `muno` exists or let Wrangler create it on
  first deploy.
- Add custom domain `muno.mestumre.dev` to the Pages project if Cloudflare does
  not attach it automatically.

Workflow behavior:

- PRs run install, type-check, tests, widget smoke, build, and artifact upload.
- Pushes to `main` do the same and then deploy to Pages if the two Cloudflare
  secrets exist.
- If Cloudflare secrets are missing, the deploy job prints a notice and skips
  without failing the build.

Security note:

- A Cloudflare API token was pasted into chat during this round. Do not reuse it
  long-term; rotate it in Cloudflare and store the replacement only as a GitHub
  secret.

