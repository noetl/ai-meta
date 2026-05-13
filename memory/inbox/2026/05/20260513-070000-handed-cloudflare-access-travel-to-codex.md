# Handed Cloudflare Access protection of travel.mestumre.dev to Codex (URGENT — Round 9)

- date: 2026-05-13T07:00:00Z
- tags: trip-planner, travel, security, cloudflare-access, auth0, edge-auth, codex-handoff, round-9

## Round goal

travel.mestumre.dev is currently PUBLIC despite PR noetl/travel#17
wiring Auth0 inside the SPA. The in-app login is soft auth — the
static SPA bundle is freely fetchable. Close the gap by configuring
Cloudflare Access at the edge of the Pages deployment, using the
existing Auth0 IdP from Cloudflare Zero Trust.

Defense-in-depth: edge gate (Cloudflare Access + Auth0) + in-app
login (Auth0 SPA flow from PR #17) = two layers. UX consolidation
(one login vs two) is a deliberate follow-up, not in this round.

## Decisions locked

- **Edge protection only**. NO server-side JWT validation. The in-app
  Bearer token from PR #17 is not validated by NoETL yet; that's a
  separate follow-up round.
- **All work via Cloudflare REST API**. CF token in GCP Secret Manager
  as `cloudflare-access-token`. Never echoed.
- **Auth0 side is Kadyapam-managed**. Codex doesn't call Auth0
  Management API. Auth0 IdP must already exist in Cloudflare Zero
  Trust before this round fires.
- **Allow rule is operator-decided**. Codex auto-detects format from
  the `cloudflare-access-allow-rule` secret (email_domain vs emails).
- **Rollback is one DELETE call** with the captured Application UUID.
  Result JSON records it prominently.
- **Documentation in repos/travel + repos/docs only**. No muno code,
  no ops manifest changes, no DNS/proxy changes.
- **In-app Auth0 SPA flow untouched**. PR #17's work stays as-is.

## Pre-handoff (Kadyapam, ~5-10 min)

1. Generate Cloudflare API token scoped to Access apps + policies
   edit + DNS read + Zone read. Provision as GCP secret
   `cloudflare-access-token`.
2. Confirm Auth0 is registered as an IdP in Cloudflare Zero Trust
   (Settings → Authentication → Login methods). If absent: add it
   (Regular Web App in Auth0 — not SPA — with client secret).
3. Decide allow rule (email domain OR specific emails). Provision as
   GCP secret `cloudflare-access-allow-rule`.

## Bridge artefacts

- `bridge/inbox/delegated/20260513-070000-cloudflare-access-travel.task.json`
- `scripts/cloudflare_access_travel_msg.txt`

## Trigger prompt for Codex

```
URGENT: protect travel.mestumre.dev with Cloudflare Access. SPA assets
are currently public despite in-app Auth0 (PR #17). Add edge gate via
Cloudflare API; Auth0 IdP already in Zero Trust. Round 9 of the
trip-planner project.

Bridge task: bridge/inbox/delegated/20260513-070000-cloudflare-access-travel.task.json
Prompt details: scripts/cloudflare_access_travel_msg.txt
Scoping doc: sync/issues/2026-05-12-trip-planner-app-scoping.md
Result file: bridge/outbox/20260513-070000-cloudflare-access-travel.result.json

Pre-handoff (Kadyapam, DONE):
  - GCP secret `cloudflare-access-token` provisioned (CF API token,
    scoped to Access apps+policies edit, audit logs read, zone read,
    DNS read). Worker SA has secretAccessor.
  - Auth0 IdP exists in Cloudflare Zero Trust (Settings →
    Authentication → Login methods).
  - GCP secret `cloudflare-access-allow-rule` set with allow rule
    (email domain `@cybx.io` OR comma-separated emails). Worker SA
    has secretAccessor.

Run all 7 phases per the bridge task. Architectural rules:
  - Edge protection only. NO server-side JWT validation.
  - In-app Auth0 SPA flow from PR #17 UNTOUCHED.
  - Codex makes Cloudflare API calls via the GCP-secret-stored token.
    Never echo the token, session cookies, or any sensitive bytes.
  - Do NOT modify other Cloudflare Access apps (list + verify only).
  - Do NOT touch DNS, proxy settings, or Auth0 config.
  - Documentation in repos/travel + repos/docs only.
  - Rollback recipe in result JSON: DELETE app UUID.
  - PRs via standard flow.
  - ai-meta pointer bumps local-only; Kadyapam pushes.

Anonymous curl probe in phase 4 MUST return HTTP/2 302 with location
to <team>.cloudflareaccess.com. If still HTTP/2 200 after 60s of
retries: AMBER + STOP.
```

## What's after this round

- **JWT validation** at NoETL — verifies the in-app Auth0 token
  server-side, ties chat events to verified user_uid.
- **Per-uid Firestore rules** — tighten from v1 permissive to
  request.auth.uid scoping.
- **Auth consolidation** — eliminate the double-login UX (edge + in-app)
  by using Cloudflare Access JWT (`CF-Access-Jwt-Assertion` header) as
  the in-app identity source.
- **Tutorial 08 update** — done as part of this round, but might want
  to add a screenshot of the Cloudflare Access challenge page later.

## Related

- `sync/issues/2026-05-12-trip-planner-app-scoping.md`
- `memory/inbox/2026/05/20260513-062528-travel-pages-auth0-stage-report.md` (current state: Pages deployed, in-app Auth0 live, asset surface unprotected)
- noetl/travel#17 — in-app Auth0 SPA flow (left alone in this round)
- https://developers.cloudflare.com/cloudflare-one/applications/configure-apps/self-hosted-public-app/
- https://developers.cloudflare.com/cloudflare-one/identity/idp-integration/auth0/
