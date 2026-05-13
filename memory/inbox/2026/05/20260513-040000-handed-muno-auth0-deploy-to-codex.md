# Handed muno deployment + Auth0 to Codex (post-tutorial Round 8)

- date: 2026-05-13T04:00:00Z
- tags: trip-planner, adiona, muno, auth0, deployment, gke, cloudflare, ingress, ghcr, codex-handoff, round-8

## Round goal

Deploy muno to https://muno.mestumre.dev with Auth0 authentication.
Two coupled deliverables in one round: (a) Auth0 SPA integration in
the React frontend; (b) GKE deployment + Cloudflare DNS for the new
subdomain.

First post-tutorial round (Round 7 = end-to-end tutorial shipped at
docs#67 on 2026-05-13). This addresses post-tutorial roadmap item #3
(auth) and adds a live URL for sharing the demo.

## Decisions locked

- **Auth0 frontend-only in v1**. No NoETL server-side JWT validation.
  Frontend trusts the user_uid; documented as a v1 trust assumption
  with TODO for follow-up server validation. Guest mode preserved as
  fallback so anonymous demos still work.
- **Firestore security rules unchanged** (still v1 permissive from
  Round 5). Tightening to per-uid rules is a follow-up round.
- **ghcr.io/noetl/muno** for the container image (mirrors noetl/noetl
  convention).
- **GKE Ingress + cert-manager** for origin TLS. Cloudflare proxy ON
  (orange cloud) for edge TLS + WAF; SSL/TLS mode Full (Strict).
- **DNS update is Kadyapam-side**. Codex outputs instructions; round
  AMBERs at phase 7 pending Kadyapam's confirmation, then resumes to
  live smoke.

## Pre-handoff (Kadyapam, ~10 min before firing)

1. **Auth0 SPA app**: register at the Auth0 dashboard. Allowed
   callback URLs: `https://muno.mestumre.dev/callback,
   http://localhost:5173/callback`. Allowed logout URLs +
   Allowed Web Origins same two. Optional API audience
   `https://api.muno.mestumre.dev`. Capture Domain + Client ID.
2. **GCP secrets**: `muno-auth0-domain`, `muno-auth0-client-id`,
   `muno-auth0-audience`. Grant worker SA `secretAccessor` on each.
3. **Maps key referrer**: add `https://muno.mestumre.dev/*` to
   `travel-agent-widget-key` allowed referrers (in Cloud Console).

## Mid-round handoff (DNS, Kadyapam, after phase 7)

Codex's phase 7 outputs the Ingress IP. Kadyapam adds at Cloudflare:
- Type: A, Name: muno, IPv4: <Ingress IP>, Proxy: Proxied (orange),
  TTL: Auto.
- After 1-2 min propagation, tell codex 'DNS added' to resume.

## Bridge artefacts

- `bridge/inbox/delegated/20260513-040000-muno-auth0-deploy.task.json`
- `scripts/muno_auth0_deploy_msg.txt`

## Trigger prompt for Codex

```
Deploy muno to muno.mestumre.dev with Auth0 authentication. Post-tutorial
Round 8 of the trip-planner project. Coupled deliverables: Auth0 SPA
integration in muno frontend + GKE deployment + Cloudflare DNS.

Bridge task: bridge/inbox/delegated/20260513-040000-muno-auth0-deploy.task.json
Prompt details: scripts/muno_auth0_deploy_msg.txt
Scoping doc: sync/issues/2026-05-12-trip-planner-app-scoping.md
Result file: bridge/outbox/20260513-040000-muno-auth0-deploy.result.json

Pre-handoff (Kadyapam, DONE):
  - Auth0 SPA app registered with callback URLs for muno.mestumre.dev
    + localhost:5173.
  - GCP secrets muno-auth0-domain / muno-auth0-client-id /
    muno-auth0-audience provisioned; worker SA has secretAccessor.
  - google-maps-widget-key referrer restrictions include
    `https://muno.mestumre.dev/*`.

Mid-round handoff: phase 7 outputs the Ingress IP. Kadyapam adds the
Cloudflare DNS record (A, muno, <IP>, Proxied orange cloud), then
tells codex 'DNS added' to resume to phase 8 live smoke.

Run all 9 phases per the bridge task. Architectural rules:
  - Auth0 frontend-only. NO server-side JWT validation in this round.
  - Guest mode preserved as fallback.
  - Firestore security rules unchanged from v1 permissive.
  - Container image goes to ghcr.io/noetl/muno (timestamped + :latest).
  - Cloudflare proxy ON (orange cloud); cert-manager origin TLS;
    SSL/TLS mode Full (Strict).
  - Never commit Auth0 secrets or token bytes.
  - muno PR + repos/ops PR (if k8s manifests land there) via standard
    flow.
  - ai-meta pointer bump local-only; Kadyapam pushes ai-meta.
  - Cloudflare DNS update is Kadyapam-side; codex outputs
    instructions and AMBERs pending DNS.

If codex's flow can't pause-and-resume mid-round at phase 7: split
into two invocations (phases 1-7 then 8-9 after DNS). Document the
chosen flow in the result JSON.
```

## What's after this round

Optional follow-up rounds enabled by this one:
- **Round 8b**: NoETL server-side JWT validation. Tightens the
  frontend-trusted user_uid to a verified-via-Auth0-JWKS chain.
- **Round 8c**: Firebase Auth on Firestore reads. Custom Firebase token
  minted from Auth0 JWT; per-uid security rules.
- **Round 6c**: mobile responsive (Figma has `mob-*` variants).
- **Photo wiring**, **booking ref polish**, **filter narrowing
  widgets**, etc. — all from the tutorial's roadmap.

## Related

- `sync/issues/2026-05-12-trip-planner-app-scoping.md`
- `memory/inbox/2026/05/20260513-030000-tutorial-08-end-to-end-green.md` (Round 7 / feature complete)
- `memory/inbox/2026/05/20260513-002608-muno-bootstrap-container-build-green.md` (Dockerfile + nginx pattern)
- `repos/gui/Dockerfile` (container packaging convention)
- `repos/ops/ci/manifests/noetl/` (deployment manifest convention)
- https://auth0.com/docs/quickstart/spa/react
