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
