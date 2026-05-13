# Handed travel gateway-session auth to Codex (Round 9 corrected — supersedes Cloudflare Access plan)

- date: 2026-05-13T08:00:00Z
- tags: trip-planner, travel, auth0, gateway, session-auth, gui-pattern-mirror, codex-handoff, round-9-corrected

## Round goal

Replace the cancelled Cloudflare Access round with the correct
gateway-mediated session auth pattern. Mirror what `repos/gui` already
does for mestumre.dev: Auth0 SPA login → exchange Auth0 token at
`gateway.mestumre.dev/api/auth/login` → store NoETL session_token →
all playbook execution carries that token.

Disable guest mode in production builds; preserve for local dev via
`VITE_ALLOW_GUEST=true` Vite env flag.

Single identity (kadyapam@gmail.com via Auth0) flows end-to-end.

## Why corrected

Original Round 9 (Cloudflare Access at the edge) was wrong for this
project's architecture. NoETL has its own session model exercised by
GUI via gateway login playbook. Travel must mirror that so auth state
flows through one path. Edge gating would have left NoETL ignorant of
identity entirely. See supersede memo at
`memory/inbox/2026/05/20260513-073000-supersede-cloudflare-access-round-9.md`.

## Discovery phase is critical

Codex MUST inspect `repos/gui` first and produce
`repos/travel/docs/auth/gateway-session-pattern.md` documenting the
GUI auth flow byte-for-byte where it makes sense BEFORE writing any
travel code. Implementation mirrors what GUI actually does — no
inference. If GUI doesn't have such a flow at all: AMBER + STOP and
ping Kadyapam.

## Architecture locked

- Auth0 SPA flow (PR noetl/travel#17) preserved. The gateway exchange
  is an EXTENSION, not a replacement.
- Production: guest mode OFF. Sign-in pane (Adiona logo + single CTA)
  replaces chat shell until `isAuthenticated`.
- Local dev: `VITE_ALLOW_GUEST=true` preserves the existing behaviour.
- No Cloudflare Access, no edge gating, no Auth0 tenant changes, no
  DNS changes, no new GCP secrets.
- Frontend Firestore live reads stay unauthenticated (v1 permissive
  rules); tightening Firestore-side is a SEPARATE follow-up round.
- Session tokens never echoed.

## Bridge artefacts

- `bridge/inbox/delegated/20260513-080000-travel-gateway-session-auth.task.json`
- `scripts/travel_gateway_session_auth_msg.txt`

The cancelled Cloudflare Access bridge task stays in place at
`bridge/inbox/delegated/20260513-070000-cloudflare-access-travel.task.json`
for audit history but is NOT fired. Supersede memo links the two.

## Mid-round handoff

Phase 6 AMBERs pending Kadyapam's live browser smoke against
travel.mestumre.dev. Checklist captured in the result JSON. Kadyapam
confirms the auth flow + chat works + the session_token appears on
gateway requests in devtools, then the round flips GREEN.

## Trigger prompt for Codex

```
Travel gateway-session auth (corrected Round 9). Mirror repos/gui's
gateway-mediated session auth pattern into repos/travel. Supersedes
the cancelled Cloudflare Access round; the cancelled bridge task
remains for audit only.

Bridge task: bridge/inbox/delegated/20260513-080000-travel-gateway-session-auth.task.json
Prompt details: scripts/travel_gateway_session_auth_msg.txt
Supersede memo: memory/inbox/2026/05/20260513-073000-supersede-cloudflare-access-round-9.md
Scoping doc: sync/issues/2026-05-12-trip-planner-app-scoping.md
Result file: bridge/outbox/20260513-080000-travel-gateway-session-auth.result.json

Pre-handoff (DONE, minimal): existing Auth0 SPA app for
travel.mestumre.dev + existing GCP secrets cover everything. No new
secrets, no new IAM.

Discovery phase 1 is CRITICAL: inspect repos/gui to map the gateway
auth pattern (endpoint, request/response shape, storage, header,
401 handling). Land the pattern doc at
repos/travel/docs/auth/gateway-session-pattern.md BEFORE writing
travel code. Implementation must mirror what GUI does.

Run all 7 phases per the bridge task. Architectural rules:
  - Mirror GUI verbatim. Inspect-then-implement.
  - Auth0 SPA flow (PR #17) preserved and extended.
  - VITE_ALLOW_GUEST=true preserves guest mode for local dev only.
  - No Cloudflare Access. No edge gating.
  - No Auth0 tenant config changes. No DNS changes. No new GCP
    secrets.
  - Frontend Firestore live reads stay unauthenticated under v1
    permissive rules — tightening is a separate follow-up.
  - Never echo Auth0 tokens, session tokens, or refresh tokens.
  - If repos/gui doesn't actually have a gateway auth flow: AMBER +
    STOP at phase 1.
  - If gateway exchange fails in Kadyapam's smoke: AMBER, leave PR
    open with pattern doc + actual error captured.
  - PR via standard flow on noetl/travel main.
  - ai-meta pointer bumps local-only.

Phase 6 AMBERs pending Kadyapam's browser smoke. Smoke checklist:
visit travel.mestumre.dev in incognito → Sign-in pane appears
(no chat shell, no Guest mode) → Auth0 login → 'Linking to gateway'
indicator → chat shell loads → start a trip → confirm devtools
shows session_token on every gateway request.
```

## What's after this round

- **JWT validation at NoETL** — verify the in-app Auth0 token (or the
  gateway session token) server-side. Today NoETL trusts the request;
  this hardens.
- **Per-uid Firestore rules** — tighten the v1 permissive rules. Pair
  with custom Firebase tokens minted from the gateway session.
- **UX consolidation** — if the Auth0 SPA + gateway exchange feels
  like two logins, consolidate. Currently they're back-to-back so the
  user sees one Auth0 dialog, then a fast 'Linking' indicator.
- **Tutorial 08 update** — done as part of this round, but might want
  to add a screenshot of the production Sign-in pane.

## Related

- `memory/inbox/2026/05/20260513-073000-supersede-cloudflare-access-round-9.md` (cancels prior round)
- `memory/inbox/2026/05/20260513-070000-handed-cloudflare-access-travel-to-codex.md` (the superseded handoff)
- `memory/inbox/2026/05/20260513-062528-travel-pages-auth0-stage-report.md` (Pages + Auth0 state going in)
- `sync/issues/2026-05-12-trip-planner-app-scoping.md`
- `repos/gui/` (source of the pattern to mirror — read-only)
- noetl/travel#17 (in-app Auth0 SPA — the foundation this round extends)
