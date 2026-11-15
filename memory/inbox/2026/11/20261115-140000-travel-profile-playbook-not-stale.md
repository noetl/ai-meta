# Travel profile playbook: prod is NOT stale — read path verified from logs; e2e blocked on gke-prod auth

- Timestamp: 2026-11-15T14:00:00Z
- Author: Kadyapam
- Tags: travel, muno, profile, firestore, diagnosis

Report: "Darya doesn't see profile data — old `muno/playbooks/profile` registered in prod?" Diagnosed read-only; **nothing re-registered**.

- **Topology (verified):** `gateway.mestumre.dev` → Cloudflare tunnel `cloudflare/noetl-gke-gateway-tunnel` (ingress hostname `gateway.mestumre.dev` → `gateway.gateway.svc:80`) in **shastaratech-noetl-prod / noetl-prod-autopilot**. That one gateway serves travel.mestumre.dev (adiona/frontend build, "Adiona — Say where you want to be") **and** mountshastaranch.com — one shared NoETL. The July records' `noetl-demo-19700101` + PF 18082 path is obsolete for travel.
- **Repo current:** noetl/travel `main` `playbooks/profile.yaml` @ 2a17331 (#145 begin_read), sha256 `201bcee08206…`, metadata.version "1.0". #146 (plan_suggestions) / #147 (delete) still unmerged.
- **Registered == repo main (by behaviour):** every prod profile execution in 30d runs main's exact step set (validate_input, begin_read, load_profile, save_profile, reject_input, skip_suggestions, suggest_pois, build_response); no `plan_suggestions`/`delete_profile` ever appears. Catalog content not read directly (gke-prod session 401; pod exec denied by permission policy).
- **Read path works:** e.g. exec 379408745983123456 (2026-11-12 23:15Z): validate→begin_read→load_profile(`get_doc users/auth0|…9320bf`)→build_response→COMPLETED, no write; build_response's rendered `loaded` input carries the full stored doc (displayName, homeCity, bookings, preferences…).
- **Firestore:** users/auth0|…9320bf (13 fields, updated 2026-11-12) and users/auth0|…2217a3 (created/updated 2026-10-15 — matches bazilevsd commit c7f49de; displayName/homeCity empty, 2 bookings). Both camelCase+snake_case.
- **Darya's account (…2217a3) has no profile executions in the 30d log window** — her traffic is the trip-intake playbook (writes chat_threads/**/slot_state/intake, thread_owners, user_thread_map — never users/{uid}).
- **Open:** e2e (save→Firestore→load) needs an operator `noetl --context gke-prod auth login --browser-pkce`; since gateway#56 the uid is bound to the session, so a save test needs a dedicated QA Auth0 account (else it writes the operator's real profile). Need Darya's repro: account, page, what she expects vs sees.

## Reconciliation: newest profile.yaml across all noetl/travel branches/PRs (2026-11-15)

- Every remote branch scanned for `playbooks/profile.yaml` ≠ main. **Only #146 (`feat/profile-suggestions-from-stored`) and #147 (`feat/profile-delete`, stacked on #146) carry commits not in main.** All other differing copies are older snapshots (0 commits ahead). No open PR from a fork, and **no Darya (bazilevsd) branch touches profile.yaml**.
- Newest MERGED = #145 (main, blob 7c0b97ec) = what prod runs → case (c), not (b). **Nothing re-registered**: prod is not behind merged main.
- #146 / #147 change no write fields and no paths: same `users/{uid}`, save step (`set_doc` merge pass-through) and load step (`get_doc`) unchanged. #146 only *reads* `home_lat`/`home_lng`/`interests` to plan suggestions; #147 adds `delete_doc` + read-back.
- The saved field set is whatever the SPA sends (`toPlaybookProfile`); Darya's doc (…2217a3) has the 13 SPA keys and no `home_lat`/`home_lng`/`interests`. Those only matter for suggestions (needs #146 + adiona/frontend#75). **The latest-vs-prod gap does not explain missing profile data.**

## Correction / open conflict (2026-11-15, after adiona/frontend#59 comment 18:44Z)

- The "registered == main" conclusion above was **by behaviour from logs, not a direct catalog read** — treat it as unconfirmed.
- bazilevsd's agent reports the login-time read ran `save_profile` and skipped `begin_read`. Prod logs do not show that: Nov 12 reads (e.g. 379408745983123456) **entered** `begin_read` and **skipped** `save_profile`, and there are **zero** profile executions / `users/` Firestore calls on this prod since 2026-11-12 (none today, none for …2217a3). Likely a save run (correctly skips begin_read) or another backend — unresolved until the catalog is read.
- Owner authorized re-registering main `playbooks/profile.yaml` (blob 7c0b97ec, sha256 201bcee0…) as `muno/playbooks/profile`. **Blocked on access:** gke-prod gateway session 401; `kubectl exec` and `port-forward svc/noetl` to prod both denied by the agent permission policy. Documented path: `playbooks/deployment/register-with-noetl.sh` (`noetl --server-url … register playbook --file`) or `noetl --context gke-prod`. Waiting on operator re-auth (`noetl --context gke-prod auth login --browser-pkce`) or a permission rule. Plan: read+pin current → register main → read_only load must run begin_read, skip save_profile, no updateTime change → reply #59.

## RESOLVED by direct catalog read (2026-11-15 19:25Z, operator gke-prod login)

- Operator context fixed: `noetl context update gke-prod --auth0-domain=shastara.us.auth0.com --auth0-client-id=ECUiHFlhT9gAR1htdSdROWn59WA0lOCH --auth0-redirect-uri=http://127.0.0.1:8765/callback` (no audience: the CLI forwards it to /authorize; server checks ID-token aud ∈ NOETL_AUTH0_AUDIENCE). Server live: NOETL_AUTH0_DOMAIN=mestumre-development.us.auth0.com,shastara.us.auth0.com; NOETL_AUTH_VERIFY_SIGNATURE=enforce.
- **Registered `muno/playbooks/profile` = v7, catalog_id 736128634880000113, created 2026-10-12T15:56:11Z, sha256 201bcee08206391d… — byte-identical to noetl/travel main (#145); read_only arc → begin_read.** Prod was NOT stale. **Nothing re-registered** (would be an identical v8). Rollback pin: v7.
- Verify: `noetl --context gke-prod exec catalog://muno/playbooks/profile --payload '{"uid":…,"profile":{},"read_only":true}'` → exec 380438259395731456 COMPLETED: validate_input RAN, begin_read RAN, save_profile skipped, load_profile RAN (get_doc only, users/google-oauth2|…726381 = operator, uid bound by gateway), build_response/end RAN. Firestore: no doc created, all profile updateTimes unchanged.
- Posted adiona/frontend#59 comment 6899983346; asked bazilevsd for the execution id her agent analysed + gateway URL (no profile execs for her uid on this prod since Oct 15).

## Local-runtime reproduction + agent guide (2026-11-15)

- **Local runtime cannot run profile.yaml** (python steps), measured with the SPA's exact payloads, creds isolated:
  - **CLI 2.17.0** (first on the operator PATH): python steps silently skipped ("Tool not supported in local execution mode"); `noetl_executor::condition::evaluate_condition` treats the unresolved `{{ validate_input.ok and validate_input.read_only }}` as truthy, so **reads and saves both route to begin_read**; then `load_profile` errors "Failed to read playbook file" (the child `automation/agents/mcp/firestore` is resolved as a local path). Zero Firestore access, so "no data".
  - **CLI 6.4.1** (latest): refuses up front ("uses tool kinds the local runtime cannot run … python" → "--runtime distributed").
  - Neither reproduces "save_profile on read". Fix = (b): profile must be tested via the gateway, now documented.
- **noetl/travel#183** (docs/scaffolding only, CI green):
  - docs/playbooks/AGENT-GUIDE.md; AGENTS.md section; skill `.claude/skills/noetl-travel-playbooks/` + `docs/playbooks/noetl-travel-playbooks.skill`.
  - spec-kit 1.4.0 (`specify init --here --integration claude --script sh`, same layout as noetl/book); constitution v1.0.0; specs/001-travel-playbooks.
  - scripts: validate_playbook_schema.py (noetl.ai schema; neg-tested), trace_execution.py (gateway GET /noetl/executions/{id}), profile_doc_read.py (read-only).
- noetl.ai facts:
  - real artifacts: `/`, `/llms.txt`, `/schema/v2/playbook.schema.json`, `/dsl/{manifest,resource-model,source}.json`;
  - **every other path returns the same 200 page**;
  - Cloudflare 403s Python's default User-Agent (gateway too); set one.
- Posted adiona/frontend#59 comment 6900248693 with all references + setup/debug/deploy commands.

## travel#183 merged + registration permission (2026-11-15)

- **noetl/travel#183 merged** `afc002febd16816b23bb0245dd09350076f25470` (2026-11-15T19:48:41Z):
  - skill `.claude/skills/noetl-travel-playbooks/` on main;
  - the `.skill` downloaded from main extracts, frontmatter valid, bundled scripts run, SKILL.md byte-identical to the repo copy.
- adiona/frontend#59 comment 6900248693 **edited to point at main**: all 6 links 200.
- **Registration needs the `admin` role.** Gateway proxy authorization (noetl/gateway `src/authorization.rs`, since v3.15.0) is always on in prod (live env has GATEWAY_USER_PLAYBOOKS).
  - Non-admin sessions may only start the allowlisted travel playbooks, and GET/cancel their **own** executions.
  - `catalog get`/`catalog/register` are admin-only. There is no narrower deployer role: admin = full proxy surface.
  - The operator CLI session has admin (its `catalog get` worked).
- Grant mechanism: noetl/ops `automation/setup/provision_auth.yaml` action `grant_admin` (INSERT auth.user_roles … WHERE u.email = $EMAIL AND role 'admin'). User must `noetl --context gke-prod auth login` once first (creates the auth.users row). Its workload defaults target a demo DB, so prod namespace/deployment/db must be confirmed.
  - ⚠ The grant matches by **email**, so every auth.users row with that email gets admin.
  - ⚠ Login copies roles to same-email accounts without an `email_verified` check (GHSA-qxw3-x3fw-qp2c item 7). Fix that before granting admin by email, or have an operator register on Darya's behalf.

## Adiona team admin account: prerequisites (2026-11-15, HOLDING: no user row yet)

- **Correction to the previous section.** The login role-copy **is** gated on `email_verified` in prod:
  - The fix is noetl/server `30862dfc` ("copy same-email roles only for a verified email"), released in v3.144.1.
  - Prod server image `server-rust@sha256:c280c2c5…` = **v3.163.1**.
  - The gateway has `NOETL_AUTH_SYNC=true`, so every login goes through the server's gated `/api/auth/login` and returns early, with no playbook fallback.
- **Residual gaps** (rollback/ops hazards; no exploit detail here, see the advisory):
  - The e2e `api_integration/auth0/auth0_login` playbook CTE is still ungated. It is only reached if `NOETL_AUTH_SYNC` is turned off, so treat that flag as **not safe to roll back** until the playbook gets the same `email_verified` gate.
  - Both grant tools match by **email** with no verification check. A grant must therefore be preceded by a plan-only read showing exactly one row, with a verified-by-construction identity.
- **Prod auth DB (confirmed from live manifests, read-only):**
  - Cloud SQL `shastaratech-noetl-prod:us-central1:noetl-shared-pg` (private IP), reached through `pgbouncer.postgres.svc.cluster.local:5432` (pgbouncer + cloud-sql-proxy).
  - The `auth` schema is accessed via the NoETL credential **`pg_auth`** (gateway `session_db_credential` default; the same credential the server's login uses).
  - There is **no `deploy/postgres`** in the prod `postgres` namespace, so noetl/ops `provision_auth.yaml grant_admin` (`kubectl exec deploy/postgres`, demo defaults) **does not apply to prod**.
- **Prod-native grant path:** catalog `shastaranch/ops/grant_role` v1 (catalog_id 743065752273420438).
  - Runs as a postgres step with `auth: pg_auth`; plan-only by default; `apply: true` grants; admin-only (not on any allowlist).
- **Plan-only run for the team address:** exec `380479142270869504`.
  - Trace: `start` RAN, `grant` **skipped**, `show` RAN → **0 rows**.
  - The account has **never logged in** to the prod gateway, so there is nothing to grant to yet.
- **Auth0 (shastara tenant, CLI client), from the public client info:**
  - Connections are Username-Password (sign-up open), msr-passwords, passwordless `email`, and `google-oauth2`.
  - adiona.org mail is Google Workspace (MX aspmx.l.google.com). The team should log in with **Google** (→ `google-oauth2|…`) or **email code** (→ `email|…`); both have a provider-verified email. They should not use password sign-up.
  - `email_verified` could not be read directly: there is no Auth0 Management access from this session.
- **Next (team, then operator):**
  1. Whoever controls the mailbox runs a one-time `noetl --context gke-prod auth login --browser-pkce --pkce-port 8765`.
  2. The operator re-runs plan-only.
  3. Apply only if exactly one row is returned and it has a google-oauth2 or email prefix.
  4. Then plan-only again to confirm roles=admin, and the team runs `catalog get` to confirm.

## Adiona team admin: login seen, grant BLOCKED on operator session (2026-11-15 ~22:40Z)

- Preview `380486027468349440` (22:35:41Z, operator session): **0 rows**. This ran *before* the team login.
- Gateway logs (read-only, identities hashed):
  - 22:37:24Z: operator re-login (gateway user 207).
  - **22:38:15Z: team-account login succeeded** (shastara, gateway user **296**, @adiona.org). It was done on the operator machine and **replaced the CLI's single gke-prod session**.
- Baseline under the team session (pre-grant, as expected): `catalog get muno/playbooks/profile` → **403 not authorized**; `run shastaranch/ops/grant_role` → **403 not authorized**. The gateway also refuses it reads of the operator's executions ("execution not owned by caller").
- **Not applied yet.** `grant_role` (preview and apply) needs an admin session, and the CLI context now holds the team's non-admin session.
  - Next: operator re-login on a separate context so the two sessions don't overwrite each other.
  - Then preview (expect exactly 1 row, `google-oauth2|`/`email|` id), apply, re-preview (roles=admin), and team `catalog get` → 200.

## Adiona team admin: still BLOCKED, wrong identity on gke-prod (2026-11-15 ~22:45Z)

- The 22:42:20Z re-login on the gke-prod context created a **new** gateway user **297** (gmail). It is **not** the admin identity used all day, which is gateway user **207** (a different gmail account).
- User 297 holds no admin: `POST catalog/resource` and `POST execute` were both refused ("proxy route refused", 22:42:54Z).
- The CLI exits 0 on 403, so a `catalog get … >/dev/null && echo ok` check is a false positive. Read the output instead.
- Nothing applied; no account or role touched. Next: log in on gke-prod with the identity behind user 207 (it worked as admin earlier today), then preview, apply, verify.

## Adiona team admin: GRANTED (2026-11-15 ~23:00Z)

- **Session check:**
  - The operator re-login at 22:55:10Z put the gke-prod session back on gateway user **207** (the admin used all day).
  - `catalog get muno/playbooks/profile` returned content (catalog_id 736128634880000113), and the gateway logged the caller as 207.
  - (The 22:46Z attempt was still 297 / 403. The output was read, not the exit code.)
- **Preview** `380491107408027648` (`grant` skipped, `show` RAN):
  - **1 row**: user_id **296**, team address, roles empty, `role_exists` true.
  - `auth0_id` is **not observable**: server result sanitization redacts any `auth0_id` key as `[REDACTED]`, and the registered SQL can't alias it.
  - The single row is the one created by the 22:38:15Z team login; no other row carries that email, so the email-matched grant could reach nothing else.
- **Apply** `380491290690723840`: `grant` RAN, **affected_rows 1**.
  - `show` was skipped in that run: it is an exclusive-arc sibling of `grant` under `start`, and the runtime skips losing siblings. So the in-run post-check never fires. Minor bug in `shastaranch/ops/grant_role`.
- **Re-preview** `380491604160421888`: **1 row, user_id 296, roles = `admin`**.
- **Authorization path:**
  - Gateway roles come from session validation (server `get_user_roles` over non-expired `auth.user_roles`; gateway session cache TTL 300 s).
  - `authorization.rs` treats the `admin` role as the full proxy surface (catalog get/register included).
  - The team's next login (or its cached session after ≤5 min) carries `admin`.
  - A **live** team-side `catalog get` was not run: there is no team context on the operator machine (its session was overwritten at 22:42Z).
- **Rollback:** `DELETE FROM auth.user_roles WHERE user_id = 296 AND role_id = (SELECT role_id FROM auth.roles WHERE role_name = 'admin');` (via a pg_auth step). No other account or role touched.

## Second operator admin: STOPPED (2026-11-15 ~23:05Z)

- Requested: grant `admin` to the operator's second gmail account (expected gateway user 297).
- Preview `380492633962717184` (operator session = user 207, admin confirmed by `catalog get` output): **4 rows** for that email (users **174, 267, 275, 297**), all with no roles.
- `grant_role` grants to every row with the email, so I **did not apply**. Nothing changed.
- Options:
  - (a) Confirm all four are the operator's own accounts (e.g. several Auth0 connections or tenants), then apply.
  - (b) Grant by `user_id = 297` only, which needs a user_id-scoped grant step that doesn't exist yet.

## Correction / reconciliation: suggestions ARE live in prod (2026-11-15 ~23:05Z)

- Full registered content of `muno/playbooks/profile` (v7, catalog_id 736128634880000113, registered 2026-10-12T15:56:11Z) was re-dumped and compared:
  - registered v7 sha256 `201bcee08206391dcdb14e31be23b5b1beff5d704bd56403c96d1a1db1a20729`;
  - noetl/travel `main` `playbooks/profile.yaml`: the **same sha256, byte-identical**. The earlier claim stands.
  - #146 head `577d7b6b` (`feat/profile-suggestions-from-stored`): `1de1f216…`, differs.
- **What was misleading:** shorthand like "#146 (suggestions) unmerged" implied suggestions weren't deployed.
  - The suggestions logic (`suggest_pois`, `poi_limit: 12`, `poi_radius_m: 5000`, and `build_response` merging into `{profile, suggestions, suggestions_error}`) has been on main since `b0ea549` (2026-09-20) and `1610b43` (2026-09-22). It **is in v7 and live**.
  - #146 only adds `plan_suggestions`, which takes coordinates and interests from the request, **else from the stored document**.
- **v7 routes:**
  - `read_only: true`: validate_input → begin_read → load_profile → (`suggest_pois` if `validate_input.has_coords`, else `skip_suggestions`) → build_response.
  - `read_only: false`: validate_input → save_profile → load_profile → same guard → build_response.
  - `has_coords` is computed from the **request's** `profile.home_lat/home_lng` only.
  - The SPA login read sends `profile: {}`, so on v7 a read **never** suggests and returns `suggestions: []`, `suggestions_error: "profile has no home_lat/home_lng; suggestions skipped"`.
  - Live proof: exec `380438259395731456` (read_only): suggest_pois **skipped**, skip_suggestions **RAN**.
  - A save gets suggestions only when the request profile carries numeric `home_lat`/`home_lng`. The first `interests` entry becomes the Places type.
- **Darya's doc** (GET-only, field shapes only): 13 fields. **No `home_lat`, `home_lng` or `interests`; `home_city` empty.**
  - So she gets no suggestions on read (by design on v7) and none on save either, unless the save request carries coordinates.
  - #146 alone would not help her: her stored doc has no coordinates to fall back on.
  - "No suggestions" is expected behaviour, not a stale deploy.
- adiona/frontend#59: my comments there never claimed suggestions were undeployed (the 2026-10-06 comment shows `suggest_pois|skip` on both routes), so there is nothing to retract. A clarifying note for Darya is optional.

## Second operator admin GRANTED + #59 note + #146 held (2026-11-15 ~23:15Z)

- **Grant:** the owner confirmed all four same-email rows are theirs.
  - Apply exec `380493646308319232` (operator session user 207, admin confirmed by `catalog get` output): `grant` **affected_rows 4**.
  - Re-preview `380493931760066560`: users **174, 267, 275, 297** all `roles = admin`.
  - No other account touched.
  - Rollback: delete those four `auth.user_roles` admin rows.
- **adiona/frontend#59 note** (comment 6902943231): v7 = main; suggestions have been live since late September. A read never suggests: the decision uses only the request's coordinates, and login sends `profile: {}`. Darya's stored profile has no coordinates or interests. Path forward: save coordinates, then #146.
- **noetl/travel#146: NOT merged, NOT registered.**
  - Rebased cleanly onto main (`ff97351`, force-with-lease from `577d7b6b`).
  - Files: `playbooks/profile.yaml` + its guard `scripts/profile_suggestions_plan_test.py`.
  - Schema valid; all guards pass locally except one.
  - CI `playbook-tests` **fails** on `scripts/hotelbeds_content_cache_test.py` (`KeyError '12345'`, "one Firestore batchGet for the search's hotel codes").
  - This failure is **pre-existing and date-dependent**: it also fails at `eca516a`, the last commit where playbook-tests passed (2026-10-24). playbook-tests has not run on main since (path-filtered), so main's green badge is stale.
  - Needs a separate fix to that test's date fixtures; then merge #146, pin v7, register, and verify a read_only run shows begin_read + plan_suggestions.
  - Note: #147 is stacked on #146's branch, so after the rebase its diff shows the old #146 commit until #147 is rebased too.
