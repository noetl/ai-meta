# Handover — Finish #169 (Auth0 JWT signature verification)

**Audience:** Codex (or a human operator) picking up the security
follow-up [noetl/ai-meta#169](https://github.com/noetl/ai-meta/issues/169).
**Mission:** take Auth0 login JWT signature verification from its
current **shadow** state all the way to **enforce**, safely, and close
#169.
**Owner:** akuksin@gmail.com. **Compiled:** 2026-07-04 (Claude session,
docs/state-sync only — no code, no prod, no flag change made here).
**Copy-paste kickoff for a Codex chat:**
[`docs/CODEX-169-HANDOFF-PROMPT.md`](CODEX-169-HANDOFF-PROMPT.md).

> **The one danger to keep in front of you at all times:** prod runs a
> **single server replica**, so there is **no partial-replica canary**.
> `shadow` verifies-and-meters but **always allows** the login. The
> moment you set `enforce`, a wrong issuer/audience/JWKS config rejects
> **100% of logins** — everyone is locked out. Every enforce step below
> is gated on a real success observation and paired with an
> **instant one-variable rollback**.

---

## 0. TL;DR — the finish sequence

1. **Trigger one real Muno login** (shadow already live) → the lazily-
   registered metrics appear.
2. **Read the shadow metric.** `noetl_auth_jwt_verify_total{mode="shadow"}`
   must show **`outcome="success"` only**. Any `bad_*` / `no_domain` /
   `jwks_unavailable` = a config mismatch to FIX FIRST (§2).
3. **Confirm the real `aud`** from that verified token (= the SPA
   `client_id`) and **set `NOETL_AUTH0_AUDIENCE`** so enforce validates
   audience too (§3). It is **unset today** = `aud` not enforced.
4. **Merge the drive-path PR** [e2e#84](https://github.com/noetl/e2e/pull/84)
   so both auth paths verify (still flag-gated; only runs when
   `NOETL_AUTH_SYNC` is off — prod has it on, so lower urgency) (§4).
5. **Flip to enforce** — the gated, high-risk step. Pre-checks pass →
   `NOETL_AUTH_VERIFY_SIGNATURE=enforce` → **immediately** verify a real
   login + latency → **instant rollback** at the first `bad_*` / failure
   (§5).
6. Both paths verifying + enforce live and stable + audience enforced +
   metrics show success ⇒ **close #169** (§7).

Nothing in steps 3–5 is a code change. They are `kubectl set env`
flips on `deploy/noetl-server-rust` plus one PR merge (step 4).

---

## 1. Context — the gap, what shipped, the danger

### 1.1 The gap

The Auth0 login path **decoded the ID-token claims without verifying
the JWT signature**: base64url-decode the payload, check
`iss`/`exp`/`sub` only. No JWKS fetch, no RS256 signature check. A
forged token carrying the right `iss`/`exp`/`sub` would have been
accepted at login. The gap lived in **two** places:

- **Server sync fast-path** — `repos/server/src/handlers/auth.rs`
  `decode_and_validate_token`. This is the **live prod path**
  (`NOETL_AUTH_SYNC=true`).
- **Drive fallback** — the `auth0_login.yaml` `start` step
  (`repos/e2e/fixtures/playbooks/api_integration/auth0/auth0_login.yaml`).
  Only runs when `NOETL_AUTH_SYNC` is **off**.

The gateway does **not** decode the JWT (it forwards `auth0_token` to
the server), so there is no gateway change.

### 1.2 What shipped

| Leg | PR | State |
|---|---|---|
| Server sync-path RS256/JWKS verify (`handlers::auth_verify`) | [server#276](https://github.com/noetl/server/pull/276) | **Merged → v3.52.0 → deployed to prod, running in `shadow`** |
| Drive-path (Python-stdlib RS256) mirror in `auth0_login.yaml` | [e2e#84](https://github.com/noetl/e2e/pull/84) | **OPEN / unmerged** (review-only, flag default off) |

The server change:

- New `handlers::auth_verify`: fetch tenant JWKS → select key by header
  `kid` → verify RS256 signature + `iss`/`exp`/`nbf` (+ `aud` only when
  `NOETL_AUTH0_AUDIENCE` set), via `jsonwebtoken`.
- `Validation::new(RS256)` rejects `alg:none` / HS256 forgeries before
  key lookup (alg-confusion closed).
- JWKS TTL-cached (`NOETL_AUTH_JWKS_TTL_SECS`, default 600); unknown
  `kid` forces a refresh → key rotation is transparent.
- Metrics `noetl_auth_jwt_verify_total{mode,outcome}` +
  `noetl_auth_jwks_total{event}`; rejection reasons logged WARN with a
  fixed taxonomy, **never** token/key/claim values.

### 1.3 Current prod state (verified 2026-07-04)

- **server-rust:v3.52.0** deployed to prod ns `noetl`,
  `deploy/noetl-server-rust`, **single replica**, pod Ready, 0 restarts.
  Built via Cloud Build (`automation/gcp_gke/assets/server/cloudbuild.yaml`,
  digest `sha256:702ed479…` — TODO-confirm the full digest against the
  live deployment before relying on it for a rollback pin).
- `NOETL_AUTH_VERIFY_SIGNATURE=shadow` — **verify + meter + log, always
  allow**. Cannot lock anyone out.
- `NOETL_AUTH0_DOMAIN=mestumre-development.us.auth0.com` — **BARE HOST**
  (see §6.3 gotcha).
- `NOETL_AUTH0_AUDIENCE` — **unset** (`aud` not enforced yet).
- Phase 5 flags `NOETL_SHARD_SUBJECT_ROUTE` + `NOETL_STATE_SHARD_GC` —
  **unset / dark** (v3.52.0 also carries #166 Phase 5; leave them off,
  out of scope for #169).
- **Plumbing proven:** JWKS reachable from the server pod
  (`.well-known/jwks.json` → 200, 2 live RS256 keys). A real login
  **will** fetch + verify.
- **Not yet captured:** `outcome="success"`. The metrics are lazily
  registered — they appear only **after** the first claims-valid login
  hits the shadow path. The only login since rollout was a malformed
  test probe (rejected at claims-decode, before the shadow block), so
  no metric has been emitted yet.

### 1.4 The danger

- **Single replica ⇒ no partial-replica canary.** You cannot flip
  enforce on "one of N" pods and watch. Enforce is **all-or-nothing**.
- **Wrong config once enforced = every login rejected.** A wrong
  issuer, a wrong/премature audience, or an unreachable JWKS turns every
  real login into a rejection. That is a full login outage.
- This is exactly why `shadow` exists: prove real prod tokens verify
  **clean** before you ever enforce.

---

## 2. Capture the shadow observation (do this first)

Shadow is already live. You need **one real, claims-valid Muno login**
to hit it, then read the metric.

### 2.1 Trigger a login

Log into Muno normally (the SPA at the prod travel URL) so a real Auth0
ID token reaches `POST /api/auth/login`. A malformed/bogus token is
rejected at the claims-decode step **before** the shadow verify block,
so it does **not** emit the metric — it must be a real login.

### 2.2 Read the metric — direct pod `/metrics` (authoritative)

```bash
# port-forward the prod server (single replica)
kubectl -n noetl port-forward deploy/noetl-server-rust 18082:8082 &

# the two lazily-registered families
curl -s localhost:18082/metrics | grep -E 'noetl_auth_jwt_verify_total|noetl_auth_jwks_total'
```

Expected once a real login has hit shadow:

```
noetl_auth_jwt_verify_total{mode="shadow",outcome="success"}  <N>
noetl_auth_jwks_total{event="fetch"}   <M>
noetl_auth_jwks_total{event="hit"}     <K>
```

### 2.3 Read the metric — GMP / PromQL (prod dashboards)

Prod metrics land in **Google Managed Prometheus (GMP)**, not
VictoriaMetrics. Query:

```promql
# should be success-only:
sum by (outcome) (noetl_auth_jwt_verify_total{mode="shadow"})

# JWKS health:
sum by (event) (noetl_auth_jwks_total)
```

### 2.4 Interpretation — what each outcome means and which knob fixes it

| `outcome` | Meaning | Fix BEFORE enforce |
|---|---|---|
| `success` | Real tokens verify clean. **This is the green light.** | — |
| `bad_signature` | Signature didn't verify against the JWKS key. Usually wrong tenant / wrong JWKS / key mismatch. | Check `NOETL_AUTH0_DOMAIN` is the correct tenant bare host; confirm JWKS URL resolves to this tenant. |
| `unknown_kid` | Token's `kid` not in the fetched JWKS (rotation or wrong tenant). | Confirm the tenant; a genuine rotation self-heals (unknown-kid forces a JWKS refresh) — recheck after next login. |
| `bad_claims` | `iss`/`exp`/`nbf` (or `aud` if set) failed. | Confirm issuer = `https://<domain>/` (trailing slash, built from the **bare** host); if `aud` set, confirm it matches the SPA `client_id`. |
| `no_domain` | `NOETL_AUTH0_DOMAIN` unset/empty → verifier can't build the issuer/JWKS URL. | Set `NOETL_AUTH0_DOMAIN` to the bare host. |
| `jwks_unavailable` | JWKS fetch failed (network / DNS / egress). | Confirm the pod can reach `https://<domain>/.well-known/jwks.json` (already proven 2026-07-04, but re-check if this appears). |

**Rule:** the metric must read **`success` only** over a real sample
before you go near enforce. Any non-success outcome is a config bug
that would have rejected that login under enforce.

---

## 3. Set the audience before enforce

Today `NOETL_AUTH0_AUDIENCE` is **unset** ⇒ `aud` is **not** validated
(signature + `iss`/`exp`/`nbf` are). To enforce audience too:

1. **Confirm the real `aud`** from the shadow-verified token. It equals
   the SPA `client_id` — the Muno SPA requests **no** custom
   `audience`, so Auth0 stamps `aud` = the app's `client_id`. The value
   lives in GSM `auth0_client.data.client_id` (project
   `noetl-demo-19700101`). **Never print the value** — read it, confirm
   it matches the token's `aud`, set it, move on.
2. **Set it** (see §5 for the exact `kubectl set env`).

Note: audience enforcement is optional-but-recommended hardening.
Signature verification alone (no `aud`) already closes the forged-token
gap. Set `aud` for defense-in-depth so a token minted for a *different*
Auth0 app in the same tenant can't be replayed.

---

## 4. Merge the drive-path PR (e2e#84)

[e2e#84](https://github.com/noetl/e2e/pull/84) adds the same RS256/JWKS
verification to the `auth0_login.yaml` `start` step (pure Python stdlib
— `urllib` JWKS fetch + `hashlib` + big-int `pow()`; no PyJWT /
cryptography dependency, so no worker image change). It is gated behind
the **same** `NOETL_AUTH_VERIFY_SIGNATURE` flag.

- This path runs **only when `NOETL_AUTH_SYNC` is off**. Prod has
  `NOETL_AUTH_SYNC=true`, so this path is **not** exercised in prod
  today — lower urgency, but it is part of closing #169 (both paths
  must verify).
- Merging it with the flag `off` (default) is byte-identical to today
  — no new failure mode. Merge it, then it is ready if `NOETL_AUTH_SYNC`
  is ever turned off.
- 34 offline unit tests ship with it (`test_start_jwt_verify.py`),
  extracted straight from the YAML so they can't drift.

**Action:** review + merge e2e#84. No prod effect while the flag is off.

---

## 5. Flip to enforce (the gated, high-risk step)

Do **not** run this until §2 shows success-only over a real sample and
§3's audience is set. Single replica = all-or-nothing; be ready to
revert in **seconds**.

### 5.1 Pre-checks (all must be true)

- [ ] `noetl_auth_jwt_verify_total{mode="shadow"}` shows **`success`
      only** over ≥1 real login (more is better).
- [ ] No `bad_*` / `no_domain` / `jwks_unavailable` in the shadow
      window.
- [ ] `NOETL_AUTH0_AUDIENCE` set to the SPA `client_id` (§3) — or a
      conscious decision to enforce signature-only for now.
- [ ] JWKS reachable from the pod (re-confirm; §2.4 `jwks_unavailable`).
- [ ] `NOETL_AUTH0_DOMAIN` is the **bare host** (§6.3).

### 5.2 Set audience (if not already)

```bash
kubectl -n noetl set env deploy/noetl-server-rust \
  NOETL_AUTH0_AUDIENCE=<SPA client_id — do NOT paste the value into logs/PRs>
kubectl -n noetl rollout status deploy/noetl-server-rust --timeout=120s
```

### 5.3 Flip to enforce

```bash
kubectl -n noetl set env deploy/noetl-server-rust \
  NOETL_AUTH_VERIFY_SIGNATURE=enforce
kubectl -n noetl rollout status deploy/noetl-server-rust --timeout=120s
```

### 5.4 Immediately verify (within seconds)

```bash
# 1) a REAL Muno login must still succeed end-to-end (do it in the SPA)
# 2) metric now under enforce mode:
curl -s localhost:18082/metrics \
  | grep 'noetl_auth_jwt_verify_total{mode="enforce"'
#    -> must be outcome="success"; any bad_* = reject = rollback NOW
# 3) login latency sane (compare to the shadow baseline; enforce adds a
#    JWKS-cache lookup, not a network round-trip on the hot path)
```

### 5.5 Instant rollback (at the first `bad_*` or login failure)

```bash
# one variable, no rebuild, effective on next request after rollout:
kubectl -n noetl set env deploy/noetl-server-rust \
  NOETL_AUTH_VERIFY_SIGNATURE=shadow
kubectl -n noetl rollout status deploy/noetl-server-rust --timeout=120s
```

`shadow` restores always-allow immediately. If something is deeply
wrong, drop the flag entirely (`NOETL_AUTH_VERIFY_SIGNATURE-`, §6.1) or
roll the image to the pre-#169 prod tag `server-rust:v3.50.0` (§6.2).

---

## 6. Reference — flag semantics, rollback, the gotcha

### 6.1 Flag tri-state (`NOETL_AUTH_VERIFY_SIGNATURE`)

| Value | Behavior |
|---|---|
| unset / `off` | **Default.** Byte-identical to pre-#169 — claims-only decode, no JWKS fetch, no new failure mode. |
| `shadow` | Verify + log + meter, **still allow** the login regardless of result. The canary lever. **← prod is here now.** |
| `enforce` | Verify and **reject** on failure. The target end state. |

Companion env:

| Env | Role | Prod now |
|---|---|---|
| `NOETL_AUTH0_DOMAIN` | Tenant **bare host**; issuer + JWKS built from it | `mestumre-development.us.auth0.com` |
| `NOETL_AUTH0_AUDIENCE` | If set, `aud` is validated (= SPA `client_id`) | **unset** (aud not enforced) |
| `NOETL_AUTH_JWKS_TTL_SECS` | JWKS cache TTL | default 600 |
| `NOETL_AUTH_JWT_LEEWAY_SECS` | clock-skew leeway for exp/nbf | default (small) |

### 6.2 Rollback ladder (fastest → heaviest)

1. `NOETL_AUTH_VERIFY_SIGNATURE=shadow` — restore always-allow (§5.5).
2. `kubectl -n noetl set env deploy/noetl-server-rust NOETL_AUTH_VERIFY_SIGNATURE-`
   — drop the flag entirely → `off` → claims-only decode.
3. Roll the image back to the pre-#169 prod tag:
   `kubectl -n noetl set image deploy/noetl-server-rust <container>=…/server-rust:v3.50.0`
   (v3.50.0 was prod before v3.52.0). Heaviest; only if the binary
   itself is suspect, not just config.

### 6.3 The bare-host gotcha (do not break this)

`verify_signature` builds the issuer via
`format!("https://{domain}/")` (mirroring the existing claims-decode
check at `repos/server/src/handlers/auth.rs:335`). Therefore
`NOETL_AUTH0_DOMAIN` **must be the bare host**
(`mestumre-development.us.auth0.com`), **not** a URL. A `https://…/`
value would produce a malformed `https://https://…//` issuer/JWKS URL
and every verify would fail — which under `enforce` is a full login
outage. Same shape applies to the drive-path (e2e#84) config.

### 6.4 Exact prod Auth0 config the verification must match

- **Issuer:** `https://mestumre-development.us.auth0.com/` (trailing
  slash; built from the bare host above).
- **JWKS:** `https://mestumre-development.us.auth0.com/.well-known/jwks.json`
  (2 live RS256 keys; reachable from the pod as of 2026-07-04).
- **Audience:** the SPA `client_id` in GSM `auth0_client.data.client_id`
  (project `noetl-demo-19700101`). **Do not print its value.**

---

## 7. Definition of done for #169

- [x] Server sync fast-path signature verification (server#276) — merged,
      deployed, running in `shadow`.
- [ ] Drive-path signature verification (e2e#84) — **merge it** (§4).
- [ ] Shadow metric shows **`success` only** over a real login sample
      (§2).
- [ ] `NOETL_AUTH0_AUDIENCE` set = SPA `client_id` (§3), so enforce
      validates `aud`.
- [ ] `NOETL_AUTH_VERIFY_SIGNATURE=enforce` live and **stable** (a real
      login succeeds; no `bad_*`) (§5).
- [ ] Close [#169](https://github.com/noetl/ai-meta/issues/169) with a
      comment citing the enforce rollout + the metric evidence + e2e#84
      merge.

Keep #169 **In progress** (not closed) until enforce is live and
stable. Update the wiki dashboard + roadmap board in the same change
set as the enforce flip (per `agents/rules/wiki-maintenance.md` Rule 0a
and `roadmap-boards.md`).

---

## 8. Guardrails (non-negotiable)

- **Single replica = all-or-nothing.** No partial canary; treat enforce
  as a full-fleet flip and be ready to revert in seconds.
- **Instant rollback** is always `NOETL_AUTH_VERIFY_SIGNATURE=shadow`
  (one variable). Know it before you flip.
- **Never print** a token, a JWKS key, a claim value, or the SPA
  `client_id` — logs, PRs, issue comments, wiki. The code already logs
  only a fixed reason taxonomy; keep human notes to the same standard.
- **Append-only** on the issue and wiki. No history rewrites.
- **No IAM / secrets / keychain changes** are needed to finish #169.
- Anything you can't verify against the live repo/issue/cluster: mark
  **TODO-confirm**, don't assert.
