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
