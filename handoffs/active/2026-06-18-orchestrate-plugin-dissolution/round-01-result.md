---
thread: 2026-06-18-orchestrate-plugin-dissolution
round: 1
from: dispatch
to: claude
created: 2026-06-18T18:05:00Z
in_reply_to: round-01-prompt.md
status: complete
---

# Phase A complete — in-server shadow + wasmtime server dep retired, merged, pointer-bumped, #110 closed

Picked up Phase A ([noetl/ai-meta#110](https://github.com/noetl/ai-meta/issues/110))
this session and took it **end-to-end**: code + wiki + validation + PR + merge +
ai-meta pointer bump + ai-meta wiki dashboard + roadmap board → Done + #110
closed. The merge go-ahead was given in round 1, so the full post-merge change
set landed in the same session. `status: complete`.

**Merged:** [server#234](https://github.com/noetl/server/pull/234) squash-merged →
server main `f3043c9`. `refactor:` is a no-release commit type under
semantic-release, so **no version bump** — stays **v3.28.0** (correct for a
dead-code removal with no behavior change). ai-meta `repos/server` pointer bumped
`80cc0e6` → `f3043c9`; `repos/noetl-server-wiki` pointer bumped to `be76279`.

State synced first: `git pull` (already up to date), server pointer confirmed at
**v3.28.0 / 80cc0e6**, #108 confirmed closed, #110 confirmed open (Todo). PROD
GKE untouched; no #49 flip prep re-run; the other session's branches left alone.

## What I retired (server)

Branch `retire-orchestrate-shadow` off v3.28.0, commit
[noetl/server@19461c1] → **PR [noetl/server#234](https://github.com/noetl/server/pull/234)**.

- `src/orchestrate_shadow.rs` — the whole module (222 lines).
- `Cargo.toml` — the `[features] orchestrate-shadow = ["dep:wasmtime"]` block
  **and** the optional `wasmtime = { version = "27", optional = true }` dep.
- `Cargo.lock` — the cranelift/wasmtime tree fell out (~1000 lines:
  `cranelift-*`, `gimli`, `addr2line`, `object`, `ittapi`, `wasmtime-*`, etc.).
  `cargo tree -i wasmtime` now matches no packages. Shared deps survived
  (`base64` 0.22.1 retained as the server's direct dep). Only `potential_utf`
  shifted in (a benign re-resolution artifact; build/test/clippy all green).
- `src/handlers/events.rs` — the `shadow_pre_state` clone + the `shadow_diff(...)`
  call in `trigger_orchestrator_inner`. The in-process drive path stays as the
  `NOETL_ORCHESTRATE_PLUGIN_DRIVE=false` fallback.
- `src/main.rs` — the `orchestrate_shadow::init(...)` boot loader (the
  `if app_config.orchestrate_plugin_shadow { ... }` block at ~L760).
- `src/lib.rs` — `pub mod orchestrate_shadow;`.
- `src/config/app.rs` — the `orchestrate_plugin_shadow` field + doc + `Default`.
- `src/metrics.rs` — `orchestrate_shadow_total()` + `record_orchestrate_shadow()`.
- `Dockerfile` — `--features orchestrate-shadow` from **both** the
  `cargo chef cook` and the `cargo build` lines.

**Kept** (as instructed): `noetl-orchestrate-plugin`'s `run_state` export (the
drive uses it) and `NOETL_ORCHESTRATE_PLUGIN_DRIVE` (default true). Also kept the
plugin-crate's own `plugins/orchestrate/tests/shadow_diff.rs` + its `wasmtime`
**dev-dep** — that's a separate tree (the plugin crate is `exclude`d from the
server workspace) and tests the plugin against its own native impl; out of scope
for the server-slimming.

## Build / test / clippy

- `cargo build --release --bin noetl-control-plane` — clean (single config now).
- `cargo test --release` — all green (incl. parity_harness 8/8, secrets/encryption suites).
- `cargo clippy --release --all-targets` — clean, no warnings.

## Kind smoke (the acceptance gate)

Built the shadow-less image `localhost/noetl-server:oc-noshadow` from the branch,
loaded into `kind-noetl` (via `podman save` → `kind load image-archive`, the
podman-provider path), rolled `deploy/noetl-server-rust` (container name is
`noetl-server`). Clean boot: `system/orchestrate@1` seeded, server listening, **no
shadow loader log line** (correctly absent), zero errors/warns.

Smoke playbook: a self-contained 4-page cursor loop (`tests/oc_smoke/cursor`,
alternating `fetch_page` ↔ `check_more` steps — the proven cursor shape; no
external HTTP). Ran it under **both** drive modes on the new image:

| Mode | Result | `__orchestrate__` in `noetl.event` | Drive evidence |
| :-- | :-- | :-- | :-- |
| `NOETL_ORCHESTRATE_PLUGIN_DRIVE=false` (in-process — the exact edited path) | COMPLETED, total=12, 4 page loops | **0** | n/a (in-process never creates them) |
| `NOETL_ORCHESTRATE_PLUGIN_DRIVE=true` (worker-driven default) | COMPLETED, 4 page loops | **0** | 10 `__orchestrate__` cmds in `noetl.command`; metric `noetl_orchestrate_drive_total` dispatched=applied=10, event_suppressed=30, skipped_in_flight=2 |

`noetl_orchestrate_shadow_total` confirmed **gone** from `/metrics` (grep count 0).

Validating the **in-process** path mattered specifically: that's the branch in
`trigger_orchestrator_inner` where the shadow hook lived, so it directly
exercises the code I edited. (Note the inverse: in default-on/worker-driven mode
the function returns early at the `dispatch_orchestrate_command` branch — the
in-process `evaluate_state` + the removed shadow code never execute — so the
removal is provably inert on the live default path.)

## PR / wiki / issue / board trail

- **PR:** [noetl/server#234](https://github.com/noetl/server/pull/234) (open,
  awaiting review/merge). Body cites `See noetl/ai-meta#110` (NOT `Closes` — #110
  closes on the ai-meta pointer bump per the handoff, not on the server-PR merge).
- **Wiki:** noetl-server-wiki@be76279 (pushed to `master`) — removed the
  `NOETL_ORCHESTRATE_PLUGIN_SHADOW` env-var row + the shadow metric from
  `deployment-specification`, trimmed the stale shadow sentence from the
  `NOETL_ORCHESTRATE_PLUGIN_DRIVE` row.
- **Issue #110:** "starting work" comment + PR/validation comment posted; board
  flipped Todo → **In progress**.
- **kind cluster restored to as-found baseline:** image reverted to
  `localhost/noetl-server:oc-pool`, `NOETL_ORCHESTRATE_PLUGIN_DRIVE=false`
  (exactly what was live when I arrived — note this differs from the prompt's
  "drive env unset → code default"; the deployment carried an explicit `=false`).

## Post-merge change set (done this session)

1. ✅ Merged [noetl/server#234](https://github.com/noetl/server/pull/234) (squash → `f3043c9`).
2. ✅ Bumped `repos/server` `80cc0e6`→`f3043c9` + `repos/noetl-server-wiki`→`be76279`
   in ai-meta (`chore(sync): bump server to f3043c9` with `Closes noetl/ai-meta#110`).
   No new version tag — `refactor:` is no-release; stays v3.28.0.
3. ✅ ai-meta wiki dashboard (Rule 0a): `Home.md` (#110 Recently-closed row +
   *Last refreshed* headline + #107 program-row note), `Sessions-Log.md` (prepended
   entry). `Releases.md` **not touched** — no new tag crossed (v3.28.0 unchanged),
   so there's no version row to add; recording the rationale here rather than
   fabricating a row.
4. ✅ Roadmap board #110 → **Done**.
5. ✅ Closed #110 (citing `noetl/server#234` + the ai-meta pointer-bump SHA).

## Issues observed

- **Self-loop cursor arcs stall the worker-driven drive.** My first corrected
  fixture had `fetch_page` arc back to `fetch_page` directly (a self-referencing
  arc). Under `drive=true` it stalled in RUNNING after one iteration — no
  loop-back command issued, two PENDING commands, no system-pool worker log for
  the EID. Restructuring to the alternating two-step shape (`fetch_page` →
  `check_more` → `fetch_page`, mirroring the real `test_pagination_cursor`
  fixture) drove cleanly to COMPLETED. **This is unrelated to #110** (the shadow
  removal doesn't touch arc evaluation, which lives in `noetl-orchestrate-core`),
  but it's a possibly-real pre-existing limitation of self-referential arcs in
  the worker-driven drive worth a separate look. Not filed as an issue yet —
  flagging here for the dispatcher to decide.
- **First fixture bug (mine, not the platform's):** the `python` tool injects
  `input:` keys as **top-level variables** in the code namespace, not as a dict
  named `input`. `i = int(input["idx"])` collided with the builtin `input()` and
  errored (`'builtin_function_or_method' object is not subscriptable`). Fixed by
  referencing the injected vars by name (`idx`, `pages`, `collected`). Worth
  knowing for anyone writing kind smoke playbooks.
- Leftover in the kind catalog: `tests/oc_smoke/cursor` v1–v3 (harmless dev
  fixtures). v1 (errored python) + v2 (self-loop) executions sit in RUNNING/odd
  states; v3 is the clean one. No cleanup done — it's a dev cluster.

## Manual escalation needed

None blocking. The only gated step is the merge of #234 + the ai-meta pointer
bump, which is the standard review/go-ahead this thread reserves.
