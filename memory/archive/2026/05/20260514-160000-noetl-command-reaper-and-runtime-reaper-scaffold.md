# NoETL command reaper + repos/doctor runtime reaper scaffold

Date: 2026-05-14

## Summary

Two-layer self-healing for the PFT v2 execution `626611573817082718`
stall. Both layers landed on feature branches, not yet merged
upstream:

- **`repos/noetl` branch `kadyapam/command-reaper-self-healing`** at
  `1fd80107`: rebuilds the in-process command reaper that was removed
  in `435e3aa6`, this time scanning `noetl.command` as the source of
  truth.
- **`repos/doctor` branch `kadyapam/runtime-reaper-scaffold`** at
  `957c6c72`: scaffolds an out-of-process runtime reaper as a **Rust
  crate** that is a thin wrapper over the existing `noetl` Rust CLI
  (`repos/cli`). Subcommands resolve to bundled YAML playbooks under
  `playbooks/` and shell out to `noetl run --runtime local`.
  Playbooks follow the canonical `repos/ops` shape — every playbook
  has a `workload.action` field with `help` as default and dispatches
  via `next.arcs[].when:` guards. Includes
  `playbooks/provision_doctor_mcp.yaml` (action: deploy/redeploy/
  status/destroy/logs/help) that provisions the doctor MCP server
  itself with inline `kubectl apply -f -` heredocs, exactly mirroring
  the way `repos/ops/automation/development/mcp_kubernetes.yaml`
  provisions the kubernetes-mcp-server. The Rust CLI exposes a
  `provision <action>` subcommand that sets the right `--set
  action=...` for that playbook. Includes a single multi-stage
  Dockerfile that bundles both the `noetl` CLI release and the
  `noetl-doctor` binary, plus 11 Rust tests (7 unit + 4 `assert_cmd`
  integration).

ai-meta pointers **not bumped yet**: follow the standard "branch →
upstream PR merge → pointer bump" sequence from `AGENTS.md`. The
worktree's pre-existing staged `repos/doctor` add (initial empty repo
at `17967589`) is unrelated and left alone.

## What the in-process reaper does

`noetl/server/command_reaper.py` (new) scans `noetl.command` directly,
not the event log:

- **Orphaned active commands** — `CLAIMED`/`RUNNING` rows whose
  `worker_id` is missing from `noetl.runtime`, marked non-ready,
  heartbeat older than `NOETL_COMMAND_REAPER_WORKER_STALE_SECONDS`
  (default 60), or whose claim has aged past
  `NOETL_COMMAND_REAPER_HEALTHY_HARD_TIMEOUT_SECONDS` (default 1800).
- **Stranded pending commands** — `PENDING` rows older than
  `NOETL_COMMAND_REAPER_PENDING_RETRY_SECONDS` (default 60).

Both queries exclude executions that already reached a terminal
lifecycle event (`playbook.completed/failed`,
`workflow.completed/failed`, `execution.cancelled`). For each
candidate, the reaper calls
`NATSCommandPublisher.publish_command(...)`. The existing
`/api/commands/{event_id}/claim` endpoint plus
`noetl.claim_policy.decide_reclaim_for_existing_claim` are the sole
authority on whether each republished notification turns into a fresh
claim or is ACKed as a duplicate. **The reaper never forces
completion, never fakes `loop.done`, never duplicates claim policy.**

Wiring: `noetl/server/app.py` lifespan adds a `RuntimeLease`
(`task_name="command_reaper"`) and an `asyncio.create_task` mirroring
`runtime_sweeper` / `auto_resume`, so only one server instance reaps
at a time. Default cadence: 60s.

Env knobs:
```
NOETL_COMMAND_REAPER_ENABLED                          (default true)
NOETL_COMMAND_REAPER_INTERVAL_SECONDS                 (default 60, min 10)
NOETL_COMMAND_REAPER_WORKER_STALE_SECONDS             (default 60, min 30)
NOETL_COMMAND_REAPER_HEALTHY_HARD_TIMEOUT_SECONDS     (default 1800, min 60)
NOETL_COMMAND_REAPER_PENDING_RETRY_SECONDS            (default 60, min 15)
NOETL_COMMAND_REAPER_MAX_PER_RUN                      (default 100)
```

Tests (`tests/test_command_reaper.py`, 9 cases, all green):

- stale CLAIMED `fetch_mds_details:task_sequence` rows surface
  (regression for event_ids 626615919199912335/337/339);
- stale RUNNING `fetch_mds_details:task_sequence` row surfaces
  (regression for event_id 626615919199912327);
- SQL scans `noetl.command`, not `noetl.event` directly;
- terminal-execution rows excluded;
- stranded PENDING rows surfaced;
- per-command publish errors do not abort the sweep;
- followers without the lease idle without scanning;
- empty-result case calls no publisher.

## What `repos/doctor` is

Single-purpose: out-of-process runtime reaper that monitoring systems
call. It is **not** a generic doctor toolkit. It inspects NoETL through
public APIs + read-only SQL **via NoETL playbooks** and delegates every
state change to NoETL.

Implementation: **Rust crate** (`noetl-doctor`). Doctor never ships its
own playbook execution engine; it shells out to the canonical `noetl`
Rust CLI in `--runtime local` mode. This is the same pattern
`repos/ops` uses for its automation playbooks.

Layout:

```
Cargo.toml, rust-toolchain.toml, rustfmt.toml, Cargo.lock
Dockerfile               # single multi-stage; bundles noetl + noetl-doctor
Makefile                 # build / test / clippy / docker
README.md
src/
  main.rs                # clap CLI: detect / reachability / repair /
                         # provision / mcp serve / playbooks
  runner.rs              # spawn `noetl run`, parse last JSON object on stdout
  report.rs              # stable Outcome JSON shape + exit-code mapping
  embed.rs               # compile-time include_str! of playbooks/*.yaml
  mcp.rs                 # axum HTTP MCP surface (POST /tools/<name>/invoke)
playbooks/
  detect_stuck_executions.yaml   # action: detect | help
  inspect_stale_commands.yaml    # action: inspect | help
  reachability_smoke.yaml        # action: probe | help
  trigger_command_reaper.yaml    # action: trigger | help
  provision_doctor_mcp.yaml      # action: deploy|redeploy|status|destroy|logs|help
tests/cli.rs             # assert_cmd integration smokes
```

CLI shape:

```
noetl-doctor detect                     # → playbooks/detect_stuck_executions.yaml
noetl-doctor reachability               # → playbooks/reachability_smoke.yaml
noetl-doctor repair trigger-reaper      # → playbooks/trigger_command_reaper.yaml
noetl-doctor repair run-playbook <path> # arbitrary local-runtime playbook
noetl-doctor provision <action>         # → playbooks/provision_doctor_mcp.yaml
                                        #   (ops-style lifecycle: deploy/redeploy/
                                        #    status/destroy/logs/help)
noetl-doctor mcp serve                  # axum HTTP MCP surface
noetl-doctor playbooks                  # list bundled playbook names
```

Either CLI subcommand or a direct `noetl run playbooks/<name>.yaml
--runtime local --set action=<verb>` works — same as how `repos/ops`
playbooks are invoked. The Rust CLI is sugar that fills in the right
`--set action=...` and adds default `--namespace` / `--expected-kube-
context` knobs.

Exit codes: `0` ok / repaired, `2` anomaly detected, `3` doctor itself
failed. Output is always pretty-printed JSON under a stable
`{action, severity, generated_at, data}` shape so monitoring pipelines
can branch on `severity` or process exit code.

MCP surface (same logic, different transport):

```
GET  /healthz
GET  /tools
POST /tools/detect/invoke
POST /tools/reachability/invoke
POST /tools/repair_trigger_reaper/invoke
```

Tests:
- `cargo test`               → 6 unit + 4 integration, all green
- `cargo clippy -D warnings` → clean
- `cargo build --release`    → 2.3 MB stripped binary

Single Dockerfile (`alpine + cargo-chef`) builds the doctor binary and
bundles the upstream `noetl` CLI release (pinned by
`NOETL_CLI_VERSION` / `NOETL_CLI_ARCH` build args). Pick role at
deploy time by overriding `CMD`: `["detect"]` for one-shot Job,
`["mcp", "serve"]` for long-running pod.

## Redeploy steps

1. Push branches and open PRs (not done from this session):
   ```
   cd repos/noetl &&
     git push -u origin kadyapam/command-reaper-self-healing &&
     gh pr create -t "feat: command-table-first runtime command reaper" \
       -B main -H kadyapam/command-reaper-self-healing
   cd repos/doctor &&
     git push -u origin kadyapam/runtime-reaper-scaffold &&
     gh pr create -t "feat: scaffold noetl-doctor runtime reaper" \
       -B main -H kadyapam/runtime-reaper-scaffold
   ```
2. Merge `noetl/noetl#<N>`. semantic-release will cut a new patch
   (likely `v2.37.9` given current `pyproject.toml`).
3. Bump ai-meta `repos/noetl` gitlink to the merged SHA + ai-meta
   `repos/doctor` gitlink to the merged SHA in a single
   `chore(sync)` commit.
4. Redeploy NoETL using the ops playbook from `repos/ops`:
   ```
   cd repos/ops &&
     noetl run automation/development/noetl.yaml --runtime local \
       --set action=redeploy --set noetl_repo_dir=../noetl
   ```
   For GKE, use the equivalent gke playbook with the new image tag.
5. Verify the reaper is running:
   ```
   kubectl -n noetl logs deploy/noetl-server | grep -i COMMAND-REAPER
   # expected:
   # [COMMAND-REAPER] Started (interval=60s, worker_stale=60s, ...)
   ```
6. Verify the runtime lease:
   ```sql
   SELECT name, status, heartbeat, runtime
   FROM noetl.runtime
   WHERE kind = 'server_api' AND name LIKE '%:command_reaper';
   ```

## PFT v2 rerun plan

1. Cancel the stuck execution (one shot, since the reaper would
   otherwise keep republishing into a now-cancelled execution):
   ```
   curl -X POST -H 'content-type: application/json' \
     -d '{"reason": "stuck in fetch_mds_details before reaper deploy"}' \
     "$NOETL_URL/api/executions/626611573817082718/cancel"
   ```
2. Re-register and start `pft_flow_test/test_pft_flow_v2`:
   ```
   noetl register repos/e2e/fixtures/playbooks/pft_flow_test/test_pft_flow_v2.yaml
   noetl run pft_flow_test/test_pft_flow_v2 --runtime distributed
   ```
3. Watch:
   - `noetl.command` count by `status` grouped by `step_name`; the new
     reaper should keep `CLAIMED`/`RUNNING` from getting stuck more
     than ~`stale_seconds`;
   - server logs for `[COMMAND-REAPER] Re-published ...` lines during
     any worker churn;
   - `noetl-doctor detect --pg-dsn ... --noetl-url ...` should return
     exit 0 once the playbook advances past facility 1 MDS.
4. Success criterion: PFT v2 advances past `fetch_mds_details` into
   facility 2 and beyond, with `pft_test_validation_log` rows landing
   per facility, exactly as the pre-stall design intended.

## Why this is the right shape

- Worker comment in `noetl/worker/nats_worker.py:1291-1293`
  ("the command reaper handles recovery") is now load-bearing again.
- Claim policy in `noetl/claim_policy.py` already encodes worker
  health / lease / hard-timeout semantics — the reaper would have
  duplicated it if it acted on rows directly. Republishing keeps the
  one decision point.
- `noetl.command` is hash-partitioned by `execution_id` with indexes
  on `(status)` and `(worker_id, updated_at)` filtered by
  `status='CLAIMED'`, so the reaper's scan is index-friendly without
  needing a new index.
- Doctor never writes; if monitoring needs an oh-shit button, it must
  be a NoETL admin endpoint (with admin auth) — doctor calls it.
