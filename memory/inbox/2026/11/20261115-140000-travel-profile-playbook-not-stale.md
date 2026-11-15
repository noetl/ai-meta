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
