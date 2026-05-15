# Muno Auth0 Deploy — DNS Handoff

Round: `20260513-040000-muno-auth0-deploy`
Status: AMBER pending DNS / managed certificate / live browser smoke

Kadyapam clarified that the expected `muno-auth0-*` values are the existing
`auth0_client` Secret Manager JSON payload in project `noetl-demo-19700101`
(`1014428265962`). The Auth0 app was updated to include
`muno.mestumre.dev`, so Codex resumed from the pre-handoff AMBER.

What landed:

- `noetl/muno#13` merged at `74075c75c75d5f7f3913ead07639436073e0e072`.
- `noetl/ops#87` merged at `e56aee60abd22b4015d603d297fa847779a701c2`.
- Muno has optional Auth0 SPA integration with guest fallback, `/callback`,
  sidebar sign-in/sign-out UI, NoETL Bearer-token injection, and `user_uid`
  forwarding.
- The container build reads only browser-safe fields from `auth0_client`
  (`domain`, `client_id`, `audience`) and the restricted
  `google-maps-widget-key`.
- GKE namespace/deployment/service/ManagedCertificate/Ingress are applied.
- GKE runs `ghcr.io/noetl/muno:20260513-auth0-amd64-050223`.
- Origin smoke succeeds with `Host: muno.mestumre.dev` against Ingress IP
  `35.190.7.25`.

Important fix discovered during deploy:

- The first image was Mac-host architecture and failed on GKE with
  `exec format error`.
- `scripts/build_container.sh` now defaults to `PLATFORM=linux/amd64`, matching
  the current GKE Autopilot nodes.

Current handoff:

Create Cloudflare DNS:

- Type: `A`
- Name: `muno`
- Content: `35.190.7.25`
- Proxy: enable after the GKE ManagedCertificate is active

If certificate provisioning stalls behind Cloudflare proxy, temporarily set the
record to DNS-only until `kubectl -n muno get managedcertificate muno` reports
`Active`, then enable orange-cloud proxy and keep SSL/TLS mode Full (Strict).

Resume trigger:

> DNS added. Resume Muno Auth0 deploy phase 8 live smoke.

Expected resume checks:

- `curl -I https://muno.mestumre.dev/`
- Browser opens `https://muno.mestumre.dev`
- Auth0 sign-in redirects back to `/callback`
- Sidebar shows the signed-in profile
- Small trip-planner prompt renders a widget

