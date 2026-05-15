# 2026-05-13 — Muno Auth0 deploy AMBER at pre-handoff

Round `20260513-040000-muno-auth0-deploy` stopped at phase 1.

GKE access was present on context
`gke_noetl-demo-19700101_us-central1_noetl-cluster`, but the pre-handoff
state did not match the bridge task:

- `muno-auth0-domain` was not found in Secret Manager.
- `muno-auth0-client-id` was not found in Secret Manager.
- `muno-auth0-audience` was not found in Secret Manager.
- A related secret named `auth0_client` exists, but the round expects
  the three normalized `muno-auth0-*` entries.
- `travel-agent-widget-key` allowed referrers currently include
  `https://mestumre.dev/*`, `https://gateway.mestumre.dev/*`, and
  `https://*.pages.dev/*`; it is missing
  `https://muno.mestumre.dev/*`.
- The cluster exposes Gateway API and GKE ManagedCertificate resources,
  but not cert-manager `Certificate` resources. The eventual deployment
  should mirror the existing gateway/Cloudflare topology rather than
  assuming cert-manager Ingress objects.

No Muno or ops code was changed. No secrets were printed. The result file
is `bridge/outbox/20260513-040000-muno-auth0-deploy.result.json`.

Next rerun condition: create or map the three `muno-auth0-*` secrets,
grant worker secret access, add the `muno.mestumre.dev` Maps referrer,
then rerun Round 8 from phase 1.
