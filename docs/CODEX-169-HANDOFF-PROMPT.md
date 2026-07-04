# Codex Handoff Prompt — Finish #169 (Auth0 JWT enforce)

Copy everything in the fenced block below into a fresh Codex chat. It is
self-contained. The full reference it points to is
[`docs/HANDOVER-169-JWT.md`](HANDOVER-169-JWT.md) in the `noetl/ai-meta`
repo (wiki mirror:
<https://github.com/noetl/ai-meta/wiki/Handover-169-JWT>).

```markdown
You are Codex, a coding/ops agent working on the NoETL platform.

## Your mission
Finish security follow-up noetl/ai-meta#169 — take Auth0 login JWT
signature verification from its current SHADOW state to ENFORCE,
SAFELY, then close the issue. Prefer small, reversible steps. Verify
after every step. Roll back instantly on any regression.

## The one danger to never forget
Prod runs a SINGLE server replica, so there is NO partial-replica
canary. `shadow` verifies-and-meters but ALWAYS allows the login. The
instant you set `enforce`, a wrong issuer/audience/JWKS config rejects
100% of logins — a full login outage. Every enforce step is gated on a
real success observation and paired with a one-variable instant
rollback (`NOETL_AUTH_VERIFY_SIGNATURE=shadow`).

## Current prod state (verified 2026-07-04)
- server-rust:v3.52.0 deployed to prod ns `noetl`,
  deploy/noetl-server-rust, SINGLE replica, pod Ready.
- NOETL_AUTH_VERIFY_SIGNATURE = `shadow`  (verify + meter + log, ALWAYS
  allow — cannot lock anyone out).
- NOETL_AUTH0_DOMAIN = `mestumre-development.us.auth0.com`  (BARE HOST —
  the code builds the issuer via format!("https://{domain}/"); a URL
  value would double-prefix to https://https://…// and break every
  verify. MUST stay a bare host.)
- NOETL_AUTH0_AUDIENCE = UNSET  (aud is NOT enforced yet).
- Plumbing proven: JWKS reachable from the pod, 2 live RS256 keys. But
  metrics noetl_auth_jwt_verify_total{mode,outcome} + noetl_auth_jwks_total
  are LAZILY registered — they appear only AFTER the first claims-valid
  login hits shadow. No `outcome=success` captured yet (only a malformed
  test probe, which is rejected before the shadow block).
- Two code legs: server sync-path (server#276, MERGED, live in shadow) and
  drive-path (e2e#84, still OPEN/unmerged — same flag; only runs when
  NOETL_AUTH_SYNC is off, and prod has it ON, so lower urgency).

## Exact Auth0 config the verification must match
- Issuer: https://mestumre-development.us.auth0.com/  (trailing slash)
- JWKS:   https://mestumre-development.us.auth0.com/.well-known/jwks.json
- Audience: the SPA client_id in GSM auth0_client.data.client_id
  (project noetl-demo-19700101). NEVER print its value.

## The finish sequence (do them in order)
1. CAPTURE SHADOW SUCCESS. Trigger ONE real Muno login, then read:
     kubectl -n noetl port-forward deploy/noetl-server-rust 18082:8082 &
     curl -s localhost:18082/metrics | grep -E \
       'noetl_auth_jwt_verify_total|noetl_auth_jwks_total'
   (or GMP PromQL: sum by (outcome)(noetl_auth_jwt_verify_total{mode="shadow"}))
   Require outcome="success" ONLY. Any bad_signature/bad_claims/
   unknown_kid/no_domain/jwks_unavailable = a config mismatch to FIX
   FIRST (domain fixes no_domain/bad_signature/bad_claims-iss; aud fixes
   bad_claims-aud; JWKS reachability fixes jwks_unavailable).
2. SET AUDIENCE. Confirm the real aud from the verified token (= SPA
   client_id), then:
     kubectl -n noetl set env deploy/noetl-server-rust \
       NOETL_AUTH0_AUDIENCE=<client_id — do NOT paste the value anywhere>
   so enforce validates aud too. (Unset today = aud unenforced.)
3. MERGE DRIVE-PATH. Review + merge noetl/e2e#84 (drive-path RS256/JWKS
   verify in auth0_login.yaml, same flag, default off = byte-identical).
   No prod effect while the flag is off / NOETL_AUTH_SYNC is on.
4. FLIP TO ENFORCE (gated, high-risk). Only after step 1 is success-only
   and step 2 done:
     kubectl -n noetl set env deploy/noetl-server-rust \
       NOETL_AUTH_VERIFY_SIGNATURE=enforce
   IMMEDIATELY: do a real Muno login (must succeed), check login latency,
   and check curl …/metrics for noetl_auth_jwt_verify_total{mode="enforce",
   outcome="success"}. At the FIRST bad_* or login failure, INSTANT
   ROLLBACK:
     kubectl -n noetl set env deploy/noetl-server-rust \
       NOETL_AUTH_VERIFY_SIGNATURE=shadow
   (Heavier fallbacks: drop the flag → `NOETL_AUTH_VERIFY_SIGNATURE-`;
   or roll image → server-rust:v3.50.0.)
5. CLOSE #169 once both paths verify, enforce is live + stable, aud
   enforced, and the metric shows success. Update the ai-meta wiki
   dashboard + roadmap board in the same change set.

## Flag tri-state (NOETL_AUTH_VERIFY_SIGNATURE)
  unset/off = claims-only decode (pre-#169, byte-identical)
  shadow    = verify + meter + log, still ALLOW  ← prod is here
  enforce   = verify and REJECT on failure       ← target

## Guardrails (non-negotiable)
- Single replica = all-or-nothing; be ready to revert in SECONDS.
- Instant rollback is always NOETL_AUTH_VERIFY_SIGNATURE=shadow.
- NEVER print a token, JWKS key, claim value, or the SPA client_id —
  in logs, PRs, issue comments, or the wiki.
- Append-only on the issue + wiki. No IAM/secrets/keychain changes are
  needed. Anything you can't verify → mark TODO-confirm, don't assert.
- Do NOT touch the dark Phase 5 flags (NOETL_SHARD_SUBJECT_ROUTE,
  NOETL_STATE_SHARD_GC) that v3.52.0 also carries — out of scope.

Full step-by-step reference (metric interpretation table, rollback
ladder, pre-check list, DoD): docs/HANDOVER-169-JWT.md in noetl/ai-meta
(wiki: https://github.com/noetl/ai-meta/wiki/Handover-169-JWT).
Report what you changed on #169 and the metric evidence.
```
