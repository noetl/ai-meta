---
thread: 2026-06-18-orchestrate-plugin-dissolution
round: 1
from: claude
to: dispatch
created: 2026-06-18T16:31:31Z
status: open
expects_result_at: round-01-result.md
---

# Session snapshot — #108 orchestrator-as-plug-in COMPLETE + the one open follow-up

> **Type:** state snapshot, not a gated task. This brings any agent to the
> latest state of the orchestrator-as-plug-in dissolution work (step 2 of the
> Server Dissolution program [#107](https://github.com/noetl/ai-meta/issues/107))
> so it can pick up cold. The only proposed next work is in **Phase A** (the
> shadow/wasmtime retirement). Everything else here is "what's true now."

[noetl/ai-meta#108](https://github.com/noetl/ai-meta/issues/108) is **CLOSED**.
The NoETL orchestrator drive now runs **off-server, on the worker pool**, as a
WASM plug-in (`system/orchestrate`), **default-on**, isolated on the system
pool, writing **zero** rows to `noetl.event`. Built + kind-validated end to end
across many slices this session; the final default-flip ((c)) shipped via
**server#233 → v3.28.0**, ai-meta pointer **5a2df3a**.

## Current state (what's true now)

- **server main:** v3.28.0 (`server#233`). ai-meta server pointer is at the
  v3.28.0 commit via ai-meta@5a2df3a (the dispatch session's bump). NOTE: this
  snapshot was authored from ai-meta@018f817 (the follow-up-(b) bump); the (c)
  bump 5a2df3a landed after. Re-`git pull` ai-meta + `git submodule status
  repos/server` to see the live pointer.
- **worker main:** worker@e2162b7 (`worker#114`, pool-affinity decline).
- **Flag default flipped:** `NOETL_ORCHESTRATE_PLUGIN_DRIVE` in the server
  config now defaults **true** (drive-on). The in-process drive branch in
  `trigger_orchestrator_inner` is **kept intact** as the `=false` fallback (NOT
  retired).
- **Revert is one command (no rebuild):**
  `kubectl --context kind-noetl -n noetl set env deploy/noetl-server-rust NOETL_ORCHESTRATE_PLUGIN_DRIVE=false`
  — verified to fall back to the in-process drive cleanly.
- **kind cluster** `kind-noetl` ns `noetl`: restored to clean baseline after the
  validations (drive env unset → code default; worker log levels back to info).
  Server/worker images during this session were `localhost/noetl-server:oc-*` /
  `localhost/noetl-worker:oc-pool`; the merged code is what matters, rebuild from
  main for any fresh validation.
- **PROD GKE is UNTOUCHED.** `gke_noetl-demo-19700101_us-central1_noetl-cluster`
  ns `noetl` was already fully on the Rust stack before this session (the #49
  flip happened ~4 days ago: `noetl` Service selector = `app=noetl-server-rust`,
  `noetl-worker-rust` 2/2, `noetl-worker-system-pool` 1/1, both secrets
  `NOETL_ENCRYPTION_KEY`+`noetl-internal-api-token` present). Prod runs image
  `server-rust:batch-dispatch-v1`, which **predates** all the #108 drive work —
  so #108's drive is NOT live in prod. The `repos/ops/runbooks/noetl-server-rust-cutover.md`
  is stale as a "prep" doc (the flip it describes already happened). See the
  memory entry "#49 prod cutover ALREADY DONE". Do NOT re-run #49 flip prep.

## How the drive works now (the mechanism, for navigation)

1. **Pure drive core** — `repos/server/orchestrate-core/` (`noetl-orchestrate-core`),
   compiles to BOTH native (linked into noetl-server) AND `wasm32-unknown-unknown`
   (0 WASI imports). Contains: renderer/template, playbook model, commands,
   evaluator, `WorkflowState`/`from_events`/`apply_event` (state.rs), and the
   orchestrator (`evaluate`/`evaluate_state`). #109 closed.
2. **The plug-in** — `repos/server/plugins/orchestrate/` (`noetl-orchestrate-plugin`,
   `exclude`d from the server workspace, built explicitly for wasm32). Exports
   `alloc` + `run` (events-input `OrchestrateInput`) + `run_state` (state-input
   `OrchestrateStateInput`) over the worker host's `memory`/`alloc`/`run`
   data-plane ABI. The worker-driven drive uses `run_state`.
3. **Seed-on-boot** — the server bakes `plugins/orchestrate` → wasm32 into its
   image (`Dockerfile` `wasmbuilder` stage → `/opt/noetl/plugins/orchestrate.wasm`)
   and seeds it into `noetl.plugin_module` at startup (`src/system_plugins.rs`,
   env `NOETL_SYSTEM_PLUGIN_DIR`=`/opt/noetl/plugins`). The worker fetches it by
   `(path,version)`+digest via the existing `HttpPluginSource`.
4. **Scheduler** — `trigger_orchestrator_inner` (`src/handlers/events.rs`): in
   drive mode, after `resolve_cursor_claim_refs`, it issues ONE
   `system/orchestrate` command (`entry: run_state`, args = the bounded
   `WorkflowState`+playbook+trigger) via `dispatch_orchestrate_command`
   (`src/handlers/execute.rs`) and returns — no in-process evaluate. An
   `orchestrate_in_flight` cache flag (`src/state.rs ExecOrchState`) serialises
   drives per execution.
5. **Apply-on-callback** — `handle_event_inner`: a **`call.done`** event for the
   reserved step `__orchestrate__` routes to `apply_worker_orchestration` →
   decode the OrchestrationResult from base64 `output_b64` →
   `apply_orchestration_result` (the extracted emission: events + real commands +
   terminal). NOT `command.completed` (that carries no output).
6. **State guard** — `WorkflowState::apply_event` ignores ALL events for
   `WorkflowState::ORCHESTRATE_META_STEP` (`"__orchestrate__"`) so the
   meta-command never phantom-creates a workflow step.
7. **Zero noetl.event burst** — `dispatch_orchestrate_command` writes the command
   ONLY to `noetl.command` (not `noetl.event`); `claim_command`/`get_command`
   read `noetl.event` first (a `pri` UNION ALL keeps it authoritative for normal
   commands) and fall back to `noetl.command` on a miss. The worker-emitted
   `__orchestrate__` lifecycle events are skipped from `noetl.event`
   (`handle_event_inner` + `claim_command`). Net: `__orchestrate__` touches
   `noetl.event` 0 times.
8. **System-pool isolation** — `publish_command_notification` routes the drive to
   `noetl.commands.system.<eid>` AND stamps `execution_pool` on the notification.
   The worker (`repos/worker/src/nats/source.rs`) parses its own segment via
   `segment_from_filter(NATS_FILTER_SUBJECT)` and `NatsCommandSource::next`
   **declines** (ACK + skip) a notification whose `execution_pool` differs from
   its segment — defence-in-depth against a drifted JetStream consumer filter.
   `CommandNotification.execution_pool` (`src/nats/subscriber.rs`). **There is NO
   worker HTTP pending-poll — the NATS consumer is the only claim vector.**

## Config flags + metrics (the durable surface)

- `NOETL_ORCHESTRATE_PLUGIN_DRIVE` — **default true** now (worker-driven drive).
  `false` = in-process fallback (kept intact). Server `deployment-specification`
  wiki documents it.
- `NOETL_ORCHESTRATE_PLUGIN_SHADOW` — default false. The in-server wasmtime
  shadow (cargo feature `orchestrate-shadow`, optional `wasmtime` dep). Used for
  slice-4 validation (529 match/0). **Still present** (see Phase A).
- `NOETL_SYSTEM_PLUGIN_DIR` — default `/opt/noetl/plugins`.
- Metrics: `noetl_orchestrate_drive_total{stage=dispatched|applied|event_suppressed|skipped_in_flight|decode_error}`,
  `noetl_orchestrate_shadow_total{result=match|mismatch|error}`.

## The slice trail (PRs, for the audit)

- #109 (Event-ABI) closed: drive core → native+wasm32. server@bfd3f77.
- #108 plug-in round: slice 1 `server#224` (0-import wasm) · slice 2 `server#225`
  (wasmtime shadow-diff) · slice 3 `server#226` (seed-on-boot) · slice 4 `server#227`
  (in-server live shadow, 529/0).
- Worker-driven cutover: worker `entry`/`run_state` `worker#113` · apply extract
  `server#228` · drive-on-the-pool `server#229` · event suppression `server#230` ·
  zero-event claim path `server#231` · pool affinity `server#232`+`worker#114`+ops#191.
- (c) default-flip: `server#233` → **v3.28.0**, ai-meta@5a2df3a, #108 CLOSED,
  board → Done.

### (c) scale-soak evidence (from the dispatch session that flipped the default)

- Cursor+fan-out 120 patients (3×40): COMPLETED 511s, **694 drives**
  (dispatched=applied, 0 decode errors), system pool +694 / shared +671 — drives
  isolated to the system pool, `__orchestrate__` noetl.event rows = 0, 0 errors.
- 5× concurrent cursor: 5/5 COMPLETED, all 67 drives system-pool, 0 burst.
- After flipping the code default (no env var set): PFT 2×30 → COMPLETED, 361
  drives, system +361 / shared +349, 0 burst — identical to explicit-on. 15/15
  normal-workload regression green.
- One honest wrinkle: a 3× concurrent PFT hit 2 postgres deadlocks, correctly
  diagnosed as a **fixture artifact** (that fixture truncates shared tables → it's
  single-execution by design), NOT a drive defect.

## Phases

### Phase A — the one open separable follow-up (retire the in-server shadow + wasmtime server dep)

Read-only to scope; do the work only on explicit go-ahead.

Now that the server no longer drives in-process by default, the **in-server
shadow** (`src/orchestrate_shadow.rs`, cargo feature `orchestrate-shadow`, the
optional `wasmtime` **server** dependency, `NOETL_ORCHESTRATE_PLUGIN_SHADOW`) is
only a validation harness — it can be retired to slim the server (drop a heavy
`wasmtime` dep + the feature). The drive itself uses the WORKER's wasmtime host,
not the server's. This round kept the `orchestrate-shadow` build feature; it was
NOT retired.

1. Decide: file a tracked ai-task issue for the retirement (recommended — it's a
   clean, separable slimming, not urgent), OR do it directly if small.
2. If doing it: remove `src/orchestrate_shadow.rs`, the `orchestrate-shadow`
   feature + optional `wasmtime` dep from `repos/server/Cargo.toml`, the shadow
   hook in `trigger_orchestrator_inner`, the `--features orchestrate-shadow` in
   the `Dockerfile`, the `orchestrate_plugin_shadow` config field +
   `NOETL_ORCHESTRATE_PLUGIN_SHADOW` doc, and the `noetl_orchestrate_shadow_total`
   metric. Keep `noetl-orchestrate-plugin`'s `run_state` (the drive uses it).
3. Validate: server builds default + tests + clippy; kind smoke (drive default-on
   still drives a small cursor flow to COMPLETED with 0 event burst); wiki +
   pointer-bump per the rules.

### Phase B — nothing pending

#108 is done. No other #108 work is queued. Unrelated open ai-task umbrellas
(#103 CQRS, #104 Event-WAL, #107 program roof) are untouched by this session and
out of scope for this thread.

## FINAL REPORT

If you pick up Phase A, write `round-01-result.md` with the standard frontmatter
(`from: dispatch`, `in_reply_to: round-01-prompt.md`, `status:
complete|partial|blocked`) and report: what you retired, the build/test/clippy +
kind-smoke results, the PR/pointer/wiki/issue trail, and any surprises with
grep-able fingerprints. If you only synced and confirmed state (no Phase A work),
say so and close the thread.

## Hard rules for this thread

- PROD GKE (`gke_noetl-demo-19700101...noetl-cluster`) is untouched — keep it
  that way unless explicitly told. Do NOT re-run #49 flip prep (already done).
- Never push to `origin/main` or merge PRs without the standard review/go-ahead.
- The other session's drift-test consumer and the CQRS branch were left alone —
  don't disturb them.
- Respect `AGENTS.md` + `agents/rules/` (pointer bumps touch wiki + issue + board
  in the same change set; ai-meta is public — no secrets).
