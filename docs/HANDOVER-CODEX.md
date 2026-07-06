# Codex Handover — Muno/Travel + Domain SLM + Safe Prod Deploy

**Audience:** Codex (an AI coding agent driven via chat).
**Mission:** keep improving the Muno/travel workflows and the travel
domain-specific SLM, and ship changes to **production safely**.
**Owner:** akuksin@gmail.com. **Date compiled:** 2026-07-04 (Claude
session). Verify anything marked **TODO** against the live repos before
relying on it.

This is the full reference. The one-paragraph copy-paste kickoff for a
Codex chat lives at
[`docs/CODEX-HANDOFF-PROMPT.md`](CODEX-HANDOFF-PROMPT.md) (also mirrored
as the wiki page
[Codex-Handover](https://github.com/noetl/ai-meta/wiki/Codex-Handover)).

---

## 0. TL;DR — the loop you will run most

1. **Edit** a playbook (`repos/travel/playbooks/itinerary-planner.yaml`)
   or an MCP agent (`repos/ops/automation/agents/mcp/*.yaml`).
2. **Register a candidate** at a temp catalog path (never overwrite the
   live path first).
3. **Drive a test-mode walk** (sandbox/test bookings only; slash-free
   `thread_id`).
4. **Promote** to the live catalog path (`latest-wins`).
5. **Verify** — login (`/api/auth/validate`) + one Paris turn +
   metrics.
6. **Roll back instantly** on any regression (re-register the prior
   version / flip a flag off / prior image).

Catalog changes (planner + MCP) are **just registrations** — no image,
no cluster roll. Server/worker/gateway/SPA changes need a build+deploy
(§4).

---

## 1. System overview

### 1.1 What Muno/NoETL is

**NoETL** is an event-sourced orchestration platform. Playbooks (YAML)
are ephemeral blueprints; workers are stateless atomic compute blocks;
the append-only **event log is the source of truth**; a shared cache
carries state between blocks. **Muno** is the travel SPA + a set of
"muno" playbooks that are the worked example of a domain app built on
NoETL.

The foundational shape (read it before designing anything):
[`agents/rules/execution-model.md`](../agents/rules/execution-model.md).

### 1.2 The off-server CQRS drive

A playbook "turn" runs as a chain of hops over **NATS JetStream**, with
**no per-turn state held on the server**:

```
client → gateway (auth/authz gate) → POST /api/execute
  → server publishes a command  (noetl.commands.*)
  → a worker CLAIMS the command  (claim atomicity = exactly-once gate)
  → worker executes one tool/step, emits an event (noetl.event, append-only)
  → the materializer projects the event; the off-server state_builder
    rebuilds WorkflowState by walking prev_event_id (no table scan)
  → next command is published … repeat until a terminal event
  → SSE/callback delivers the render to the SPA
```

- The **drive** runs on the **system worker pool** (`NOETL_STATE_BUILDER=offserver`).
- The **user/rust pool** (`noetl-worker-rust`, KEDA-scaled on NATS lag)
  runs the tool steps.
- Auth is **NOT** on the drive anymore — it runs in-process on the
  server (sync fast-path, §1.5) so a wedged drive can't lock out login.

### 1.3 The itinerary-planner guided sequence

`repos/travel/playbooks/itinerary-planner.yaml` (live catalog path
`muno/playbooks/itinerary-planner`) walks a fixed sequence. Each stage
is gated on the previous stage's results existing in slot-state:

```
place/region → dates → travellers/party → flights → hotels
  → activities → transfers → summary → map
```

Gate logic lives in the `extract_turn` step (~lines 802–920). Key
gates (verified 2026-07-04):
- flights: `region_ready and dates_ready and party_ready and not flight_search_results`
- hotels: `picked_flight and not hotel_search_results`
- activities: `picked_flight and hotel_search_results and not activity_search_results`
- transfers: `picked_flight and activity_search_results and not transfer_search_results`
- summary: `picked_flight` (fall-through after all stages)
- map: after the user taps **Confirm** → `trip_confirmed=True` → `trip_map`

**Current live planner = v66** (cid `663751206480642967`). v66 dropped
the `order_id` gate that made TEST bookings (which routinely fail in
Duffel sandbox) dead-end at a premature summary, and added
`["__searched__"]` sentinel markers so empty provider results still
advance the chain. Rollback = **v65** (cid `662902606028604309`).

### 1.4 Providers (all sandbox/test only)

MCP agent playbooks live in `repos/ops/automation/agents/mcp/`:

| Provider | Path | Mode |
|---|---|---|
| Google Places (place search + geocode + photos) | `google-places.yaml` | live API, WI metadata-token auth |
| Duffel (flights) | `duffel.yaml` | **TEST token** — sandbox bookings only |
| HotelBeds (hotels) | `hotelbeds.yaml` | **SANDBOX** `api.test.hotelbeds.com` |
| HotelBeds (activities) | `hotelbeds-activities.yaml` | SANDBOX |
| HotelBeds (transfers) | `hotelbeds-transfers.yaml` | SANDBOX |

Credentials resolve from the **NoETL keychain** by alias inside the
playbook — never from env. Never switch to production booking
endpoints.

### 1.5 Current prod live state (2026-07-04)

| Component | Live version | Notes |
|---|---|---|
| **noetl-server** | **v3.50.0** (AR `server-rust:v3.50.0`) | v3.51.0 is tagged/merged but **NOT rolled** — see below |
| **noetl-worker** | **v5.52.0** (`ghcr.io/noetl/worker:v5.52.0`) | #166 Phases 1–4 live on system pool |
| **gateway** | merged main (latest release tag **v3.4.1**) | `NOETL_AUTH_SYNC=true` + `NOETL_AUTHZ_SYNC=true` |
| **planner** | catalog **v66** cid `663751206480642967` | rollback v65 cid `662902606028604309` |
| **Duffel MCP** | v18 | test token |
| **HotelBeds MCP** | v5 | sandbox |
| **SPA** | keyed bundle on Cloudflare Pages | GitHub Actions WIF build |

**v3.51.0** (tagged, merged to server `main`) carries, all **flags
default OFF**, so rolling it is behavior-neutral until a flag flips:
- #169 Auth0 JWT signature verification dark-launch
  (`NOETL_AUTH_VERIFY_SIGNATURE`, default `off`).
- #166 Phase 5 legs: server#273 server-routed per-shard publish
  (`NOETL_SHARD_SUBJECT_ROUTE`, `NOETL_COMMAND_SHARD_COUNT`) + server#275
  state-shard GC classify (`NOETL_STATE_SHARD_GC`).

**#166 Phase 4 (execution-affinity) IS live on the system pool** as
**two single-replica Deployments** (`noetl-worker-system-pool` shard 0 +
`noetl-worker-system-pool-shard1` shard 1) sharing one durable consumer
`noetl_worker_system_rust`, with `NOETL_STATE_AFFINITY_ROUTE=true`,
`NOETL_SHARD_COUNT=2`. The rust/user pool is untouched.

---

## 2. How to iterate on travel workflows

### 2.1 The catalog-registration deploy model (latest-wins)

Playbooks and MCP agents deploy by **registering YAML to the catalog**.
The catalog keeps every version; registering a path makes the newest
version the active one (`latest-wins`), and registering the prior YAML
again is a clean rollback — **no destructive edit, no image, no roll**.

Helper (in this repo): **`scripts/register_planner.py`**. It rewrites
`metadata.name` + `metadata.path` so you can register a candidate at a
temp path without touching the live planner, or promote to the live
path.

```
Usage: python3 scripts/register_planner.py <src_yaml> <target_path> [target_name]
# POSTs to http://localhost:18082/api/catalog/register  (port-forward the server)
```

**Full iterate → test → promote → rollback loop:**

```bash
# 0. Port-forward the prod server (ns noetl)
kubectl --context <prod-ctx> -n noetl port-forward svc/noetl-server-rust 18082:8082 &

# 1. Register a CANDIDATE at a temp path (live planner untouched)
python3 scripts/register_planner.py \
  repos/travel/playbooks/itinerary-planner.yaml \
  muno/playbooks/itinerary-planner-cand

# 2. Drive a TEST-mode walk against the candidate path
#    (thread_id MUST be slash-free — see §2.3). Helper: scripts/v66_verify_drive.py
curl -s localhost:18082/api/execute -H 'content-type: application/json' -d '{
  "path":"muno/playbooks/itinerary-planner-cand",
  "workload":{"event_payload":{"text":"Trip to Paris"},"thread_id":"cand-verify-p1"}}'
# … tap through place → dates → party → flights → select → hotels → activities
#    → transfers → summary → confirm → map, bounded per-turn (~90s cap).

# 3. PROMOTE to the live path (latest-wins → becomes the active version)
python3 scripts/register_planner.py \
  repos/travel/playbooks/itinerary-planner.yaml \
  muno/playbooks/itinerary-planner

# 4. ROLLBACK if needed: re-register the PRIOR yaml to the live path.
#    (Keep the previous good YAML/cid handy; latest-wins makes it active again.)
```

Confirm the active version/cid after registering through the Rust
server API:

```bash
curl -s localhost:18082/api/catalog/resource \
  -H 'content-type: application/json' \
  -d '{"path":"muno/playbooks/itinerary-planner","version":"latest"}'
```

or drive one turn and read the `GET /api/executions/{id}` payload. Old
executions stay pinned to their original `catalog_id`; only fresh runs
resolve the latest catalog version.

The travel repo also ships `scripts/itinerary_agent_smoke.sh`, which
registers via the CLI (`noetl register playbook --file …`) straight to
the live path — fine for local/kind, **not** for the candidate→promote
prod flow (no temp path). Prefer `register_planner.py` for prod.

### 2.2 MCP agents

Same model: edit `repos/ops/automation/agents/mcp/<provider>.yaml`,
register a candidate path, drive a walk that hits that provider, promote.
Provider credentials stay in the keychain by alias — never inline.

### 2.3 Thread / slot-state notes

- **Slots persist per thread** at `chat_threads/{thread_id}/slot_state/current`,
  rebuilt from the append-only event log (a projection, not truth).
- **The "no slash in thread_id" gotcha:** when you drive via the API,
  pass a **slash-free** `thread_id`. The planner's `normalize_input`
  step prepends `chat_threads/` and strips slashes; a `thread_id` that
  already contains slashes corrupts the slot-state path. Use e.g.
  `cand-verify-p1`, not `chat/threads/1`.
- **Guided-sequence gates** are strictly ordered (§1.3). If a stage
  seems stuck, check that the previous stage wrote its `*_search_results`
  (or `["__searched__"]` sentinel) into slot-state.

---

## 3. How to train the domain-specific SLM

Goal: eventually replace the OpenAI/Gemini planner calls with a small
local model (`qwen2.5-1.5B` LoRA) for the travel domain. This is an
**MLOps-as-playbooks** pipeline (umbrella
[#139](https://github.com/noetl/ai-meta/issues/139)); today it is
**review-only — nothing runs on prod, no GPU, no scheduled loop.**
Champion model today = **v3** (per memory; a v4 iteration was a negative
result).

### 3.1 Where the pieces live

**Stage playbooks (on `repos/ops` main), under `automation/mlops/slm/`:**

| Stage | Path | Purpose |
|---|---|---|
| dataset_build | `dataset_build.yaml` | seed corpus + deterministic oracle → split train/eval → `train.jsonl`/`eval.jsonl` + `manifest.json` |
| replay | `replay.yaml` | ingest real executions from the server HTTP API (GET-only), extract input + production label, redact PII → corpus JSONL |
| finetune | `finetune.yaml` | train the multitask LoRA (roles: `extract` + `render`), register the model to the G3 registry (`mode=local\|mlx\|container`) |
| eval | `eval.yaml` | metrics (match-rate vs floor/ceiling), gate vs targets → `eval_report.json`; candidate = deterministic oracle OR the SLM |
| package | `package.yaml` | merge/export LoRA, model card + eval report, register a G3 **release** (lineage → [model, eval]) |
| registry | `registry.yaml` | G3 registry smoke: register/list/resolve/lineage/artifact put+get |

Engine libs are under `automation/mlops/slm/lib/` (`slm_dataset_build.py`,
`slm_teacher.py` = Gemini teacher via Workload-Identity OAuth, `slm_replay.py`,
`slm_finetune.py`, `slm_eval.py` incl. `_compute_ceiling()`, `slm_package.py`,
`slm_registry.py`, `slm_serve.py`, `slm_infer.py`, `slm_shadow.py`, …).

**Travel domain config:**
`repos/travel/automation/mlops/slm/travel/slm.config.yaml` — the org
config (roles, teachers=Gemini 2.5-flash, data sources scoped to
`tenant=muno/project=travel`, champion marker). An example second-domain
config ships at
`repos/ops/automation/mlops/slm/examples/support_triage/slm.config.yaml`.

**Continuous-improvement loop (`improve.yaml`) — NOT on main.** It was
built review-only on **unmerged PR ops#223** (branch
`kadyapam/slm-improve-loop`): `automation/mlops/slm/improve.yaml` +
`lib/slm_improve.py` (subcommands `harvest`/`gate`/`train`/`eval-promote`/`report`/`run`).
Five stages, two gates: HARVEST → THRESHOLD GATE (`min_new_real_turns`,
travel=200) → TRAIN → EVAL+PROMOTION GATE (promote only if **no field
regresses** vs champion AND all thresholds met) → REPORT. To run it you
must first check out that branch. **TODO for Codex:** confirm whether
ops#223 has since merged; if not, work from the branch.

### 3.2 Outputs / registry

- Models, datasets, evals, releases land in the **G3 registry** as
  `registry://<domain>/<...>` URNs, server-mediated via
  `/api/internal/registry/*` + `/api/internal/objects/*` (needs
  `NOETL_REGISTRY_ENABLED=true`). Champion = the latest G3 `release` for
  `<domain>_slm_multitask`.
- For CI/local runs without a server/GPU, the engines support
  `NOETL_REGISTRY_BACKEND=local` (stub backend).

### 3.3 Run a training iteration (local/kind first)

```bash
cd repos/ops
# each stage is a NoETL playbook run; share a run_dir across stages
noetl run automation/mlops/slm/dataset_build.yaml --runtime local --set ...
noetl run automation/mlops/slm/finetune.yaml      --runtime local --set ...
noetl run automation/mlops/slm/eval.yaml          --runtime local --set ...
noetl run automation/mlops/slm/package.yaml       --runtime local --set ...
```

**TODO for Codex:** read each stage YAML's `workload`/`--set` inputs and
fill the exact `--set` keys (domain config path, run_dir, champion ref)
before running. Do a local/kind pass first; do **not** schedule the loop
on prod or flip `slm_shadow.enabled` without an explicit go — the shadow
planner leaf stays **OFF** (a prior inclusive multi-match fork wedged
orchestrate; see [#154](https://github.com/noetl/ai-meta/issues/154)).

---

## 4. How to deploy / make production-ready

Deploy path depends on the component. **Always verify login after any
backend change** (§4.5).

### 4.1 Planner + MCP agents — catalog registration

No image, no roll. Candidate → drive → promote → verify → rollback, per
§2.1. This is the fast, safe path and covers most travel iterations.

### 4.2 server & gateway (Rust images)

- **CI:** semantic-release on merge to `main` cuts a tag and publishes
  `ghcr.io/noetl/server:<version>` (`.github/workflows/release.yml`).
- **Prod, however, pulls from Artifact Registry.** The prod image is
  built with **`gcloud builds submit`** → AR (`server-rust:<tag>`,
  `noetl-gateway:<tag>`, project `noetl-demo-19700101`); `.gcloudignore`
  excludes the ~135 GB `target/`. Builds take ~25–30 min.
- **Roll:** update the Deployment image (`kubectl set image` / helm) in
  ns `noetl` (server) / ns `gateway`. Roll the **neutral** image first
  (endpoint inert / flag off), then flip the flag.
- **Rollback:** flip the flag off (instant), or roll the prior AR image.

**TODO for Codex:** confirm the exact `gcloud builds submit --config`
invocation / AR repo path from a recent deploy before building.

### 4.3 worker (Rust image)

- semantic-release `release.yml` builds **multi-arch** (amd64 +
  arm64 native runners, `imagetools` manifest merge) →
  `ghcr.io/noetl/worker:<version>`. **Prod pulls ghcr directly** — no AR
  promotion.
- Note: a GITHUB_TOKEN-pushed tag may not auto-trigger `release.yml` —
  if no build fires, dispatch `gh workflow run release.yml -f version=X`
  (and watch for a duplicate run to cancel).
- **Roll:** `kubectl set image` the worker Deployment(s). For the system
  pool remember there are now **two** Deployments (shard 0 +
  `-shard1`). **Rollback:** prior ghcr tag, or flip the flag off.

### 4.4 SPA (Cloudflare Pages)

- **Only** the keyed **GitHub Actions** workflow
  `repos/travel/.github/workflows/cloudflare-pages.yml` may publish to
  the production alias. It authenticates via **Workload Identity
  Federation**, fetches `VITE_GOOGLE_MAPS_KEY` from the GSM secret
  **`maps-java-script-api`**, and **refuses to build keyless**
  (`if [[ -z "$MAPS_KEY" ]]; then exit 1`).
- **NEVER** run a manual/local `wrangler pages deploy` — a keyless
  bundle bakes an empty Maps key → map + photos break. This is the exact
  failure mode in **[#177](https://github.com/noetl/ai-meta/issues/177)**
  (the native Cloudflare Git integration races the keyed build; the
  operator must disable it in the Cloudflare dashboard).
- **Rollback:** re-run the last good keyed Actions run, or roll the
  Cloudflare Pages deployment back to the prior keyed build.

### 4.5 Verification (do this every time)

1. **Login** (after **every** backend change):
   `POST http://<gateway>/api/auth/validate {"session_token":"bogus"}` →
   **200 `{"valid":false}` in <1 s**. Prod gateway LB `34.46.180.136`.
2. **Drive a Paris turn:**
   `POST http://<server>:8082/api/execute {"path":"muno/playbooks/itinerary-planner","workload":{"event_payload":{"text":"Trip to Paris"},"thread_id":"<slash-free>"}}`
   → execution **COMPLETED**, first render `place_list`. Capture a real
   workload shape from a recent exec via `GET /api/executions/{id}` if
   needed.
3. **Metrics:** watch GMP (Google Managed Prometheus is prod monitoring,
   not VictoriaMetrics) — e.g. `noetl_worker_affinity_decisions_total`,
   `state_builder_evictions_total`, `noetl_auth_sync_total`.

### 4.6 Key feature flags + safe defaults

| Flag | Where | Safe default | Effect when flipped |
|---|---|---|---|
| `NOETL_AUTH_SYNC` | gateway | **true (LIVE)** | in-process login/validate fast-path (off drive) |
| `NOETL_AUTHZ_SYNC` | gateway | **true (LIVE)** | in-process per-turn authz gate |
| `NOETL_AUTH_VERIFY_SIGNATURE` | server + auth0_login | **off** | `shadow` = verify+meter/allow; `enforce` = reject bad sig. **Not rolled** (#169) |
| `NOETL_STATE_BUILDER` | worker | `offserver` (system pool) | off-server drive |
| `NOETL_STATE_INDEX_SLIM` / `_TTL_SECS` / `_MAX_BYTES` / `_REHYDRATE_ON_MISS` | system-pool worker | **on** (TTL=900, MAX_BYTES=268435456) | bounded WAL index — the OOM cure (#166 Ph1) |
| `NOETL_STATE_AFFINITY_ROUTE` / `NOETL_SHARD_INDEX` / `NOETL_SHARD_COUNT` | system-pool worker | **on** (COUNT=2) | 2-shard execution affinity (#166 Ph4) |
| `NOETL_SHARD_SUBJECT_ROUTE` / `NOETL_COMMAND_SHARD_COUNT` | server | **off** (1) | server-routed per-shard publish (#166 Ph5, not rolled) |
| `NOETL_STATE_SHARD_GC` | server | **off** | state-shard GC (#166 Ph5, not rolled) |

---

## 5. Guardrails (do NOT violate)

- **Append-only event log.** `noetl.event` is immutable; replay is the
  source of truth. To stop a stuck execution, emit an **append-only
  `playbook.failed`** via the proper playbook path — **never** `DELETE`
  or `UPDATE` SQL against `noetl.*`. Workers reach `noetl.*` via the
  **server API only** (connection-pool isolation + sharding readiness).
- **Sandbox/TEST bookings only.** Duffel test token; HotelBeds
  `api.test.hotelbeds.com` with the `_is_sandbox` gate. Never real
  bookings, never production provider endpoints.
- **Verify LOGIN after every backend change** (§4.5). Login lockouts
  are the recurring prod incident class here.
- **Instant rollback on any regression** — re-register the prior planner
  version, flip a flag off, or roll the prior image. Don't debug forward
  on prod.
- **Serialize shared-tree code sessions.** `repos/server`,
  `repos/worker`, `repos/travel` — use `git worktree` to avoid
  concurrent-checkout corruption.
- **Do NOT touch:** OQ5 `result_store` dual-write (retired + frozen,
  #154); #156 off-server tail-attach (flag stays **OFF** — it broke
  auth); the SLM shadow leaf (stays OFF, #154); IAM bindings;
  secrets/keychain values.
- **Never print secret / key / token / claim values** in logs, PRs,
  issues, or the wiki (public repo).
- **JWT signature is NOT enforced in prod today** — login is a
  claims-only decode. The verify path (#169) is dark-launched
  (flag off); the shadow→enforce canary is still gated on an explicit
  go. Don't flip `NOETL_AUTH_VERIFY_SIGNATURE` to `enforce` without the
  canary sequence (wrong `aud`/issuer config breaks **all** logins).

---

## 6. Open work / suggested next steps

**Travel workflow brush-up (catalog-registration path, low risk):**
- Richer itinerary **summary** — per-currency subtotals, correct
  `total_cost` roll-up (the #174 class of bug: don't roll a booked
  offer to $0, don't label "(booked)" without a confirmed order id).
- Activities/transfers **card polish** — keep card payloads under the
  ~100 KB result-tier offload budget (blank-render cause, #164);
  real photos with graceful placeholder fallback.
- **Error UX** — friendly `user_message` on provider 4xx/5xx, raw blob
  kept in `_meta` only (done for Duffel + HotelBeds #175; sweep for any
  remaining raw-blob leaks).
- **Latency** — the planner turn floor is ~22–45 s; off-server per-hop
  latency (#130/#156) is the remaining tax.
- **HotelBeds #175** — hotel photos via Content API, booking
  price-tolerance, error-blob leak (mostly landed; verify on prod).

**SLM:**
- Run a local/kind training iteration through
  dataset_build → finetune → eval → package; measure vs the v3 champion;
  only promote a **non-regressing** candidate. Keep everything
  review-only until an explicit prod go.

**Gated rollouts (need explicit human go-ahead — do not self-trigger):**
- **#169** JWT verify: roll v3.51.0 flag-unset → `shadow` on one replica
  → watch `noetl_auth_jwt_verify_total{mode="shadow"}` success-only →
  confirm real `aud` (set `NOETL_AUTH0_AUDIENCE`) → `enforce` one replica
  → fleet. Instant revert = `off`.
- **#166 Phase 5:** roll v3.51.0, then Mode A (`NOETL_SHARD_SUBJECT_ROUTE`
  on, per-shard consumers) → Mode B (dedicated per-shard consumers) → GC
  (`NOETL_STATE_SHARD_GC` dry-run → enable). Kills the Phase-4 NAK
  redirect tax.
- **#177:** operator disables the Cloudflare native Git integration for
  the `travel` Pages project (dashboard action — cannot be automated).

---

## 7. Repo map (submodules under `repos/`)

| Repo | Role | Key paths for this work |
|---|---|---|
| `repos/travel` | Muno SPA + muno playbooks | `playbooks/itinerary-planner.yaml`; `.github/workflows/cloudflare-pages.yml`; `automation/mlops/slm/travel/slm.config.yaml` |
| `repos/server` | Rust control plane | `src/handlers/auth.rs`, `src/handlers/auth_verify.rs`; `.github/workflows/release.yml` |
| `repos/worker` | Rust worker (NATS pull loop, tool dispatch) | `src/state_builder.rs`; `.github/workflows/release.yml` |
| `repos/gateway` | HTTP edge (auth/authz gate, SSE) | `src/auth/mod.rs` |
| `repos/ops` | manifests + automation | `automation/agents/mcp/*.yaml`; `automation/mlops/slm/*`; `automation/development/noetl.yaml` (kind redeploy) |
| `repos/e2e` | e2e fixtures + auth playbooks | `fixtures/playbooks/api_integration/auth0/auth0_login.yaml` |
| `repos/ai-meta` (this repo) | issues/roadmap/wiki/memory | `scripts/register_planner.py`, `scripts/v66_verify_drive.py`; `docs/`; `repos/ai-meta-wiki/` |

**Kind (local) validation recipe** (from `repos/ops`):
```
noetl run automation/development/noetl.yaml --runtime local \
  --set action=redeploy --set noetl_repo_dir=../noetl
```
Validate on kind before any GKE roll (see
[`agents/rules/deployment-validation.md`](../agents/rules/deployment-validation.md)).

---

## 8. Deeper detail / source of truth

- Issues (durable task store):
  `gh issue list --repo noetl/ai-meta --state open --label ai-task`
  — esp. #166, #169, #175, #177, #139 (+ #140–#150 SLM sub-issues).
- Roadmap board: <https://github.com/orgs/noetl/projects/3/views/1>.
- ai-meta wiki dashboard: <https://github.com/noetl/ai-meta/wiki>
  (Home, Sessions-Log, Releases, Umbrella-Domain-SLM-Platform).
- Rules that bind this work: `agents/rules/execution-model.md`,
  `data-access-boundary.md`, `deployment-validation.md`,
  `issue-tracking.md`, `writing-style.md`.

**Anything marked TODO above must be confirmed against the live repo
before you rely on it — do not fabricate.**
