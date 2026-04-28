# Deploy latest releases to kind + nushell-style theme branch
- Timestamp: 2026-04-28T15:16:31Z
- Author: Kadyapam
- Tags: deploy,kind,gui,theme,nushell,smoke,e2e

## Summary
Bumped `repos/docs` after PR merge (`88580e8` → `35a778c` via `1c86b24`), then redeployed the latest released images of `noetl-server` (`v2.24.2`), `noetl-worker` (`v2.24.2`, 3 replicas), and `noetl-gui` (`v1.1.2`) onto local kind via the ops playbooks (`automation/development/noetl.yaml`, `automation/development/gui.yaml`). Verified `test-server` and `kubernetes-mcp-server` survived the redeploy. Post-deploy smoke probes via the gateway returned 200 across `/api/health`, `/api/executions`, `/`, `/catalog`, `/env-config.js`; new execution `615068195786850757` is processing `run_mds_batch_workers` cleanly against the patched MDS sub-playbook v7. Separately landed a topic branch `kadyapam/nushell-themes` in `repos/gui` (`4276931`) that rebuilds dark+light themes around a hybrid nushell.sh aesthetic — sans-serif chrome with mono terminal/data, calm slate-and-cream surfaces, type-tag color tokens for shell-style structured values, header gets a subtle gradient accent line and the runtime context renders as a chip.

## Actions
- `repos/docs`: fast-forwarded `main` to upstream tip after PR merge; ai-meta `1c86b24 chore(sync): bump docs to merged SHAs`.
- Built `scripts/DeployToKind.app` (launchd-spawned, bypasses oh-my-zsh interactive prompts that ate path slashes from `.command` launchers earlier today).
  - Pushed `repos/gui` topic branch `kadyapam/nushell-themes` to `origin/kadyapam/nushell-themes`.
  - Verified `test-server` `paginated-api` still Running after 10h.
  - Ran `noetl run automation/development/noetl.yaml --runtime local --set action=deploy --set registry=ghcr.io/noetl --set image_name=noetl --set image_tag=v2.24.2 --set image_pull_policy=Always`; rollout completed for `noetl-server` and `noetl-worker`.
  - Ran `noetl run automation/development/gui.yaml --runtime local --set action=deploy --set image_repository=ghcr.io/noetl/gui --set image_tag=v1.1.2 --set image_pull_policy=Always --set api_mode=direct --set api_base_url=http://722-2.local:8082 --set allow_skip_auth=true --set mcp_kubernetes_url=/mcp/kubernetes --set mcp_kubernetes_upstream=http://kubernetes-mcp-server.mcp.svc.cluster.local:8080`; helm release `noetl-gui` upgraded to revision 2.
- Built `scripts/SmokeTest.app` and `scripts/StatusCheck.app` to verify probes + watch the freshly fired execution. Smoke probes returned 200 across the GUI and gateway endpoints; env-config.js content confirmed `VITE_API_BASE_URL=http://722-2.local:8082`, `VITE_APP_VERSION=v1.1.2`, `VITE_API_MODE=direct`, `VITE_ALLOW_SKIP_AUTH=true`. Worker pool `/api/pool/status` reported `pool_size=2 available=2 utilization=0`; `/api/worker/pools` reported `total=214 by_status={'offline':211,'ready':3}` (211 offline are the same pre-existing zombies tracked separately).
- Triggered `tests/fixtures/playbooks/pft_flow_test/test_pft_flow` execution `615068195786850757` via `/api/execute`; status RUNNING with command.issued → claimed → completed and call.done/step.exit COMPLETED cycles on `run_mds_batch_workers` — the patched sub-playbook v7 is being picked up correctly post-redeploy.
- `repos/gui` `kadyapam/nushell-themes` (`4276931 feat(theme): rebuild dark + light themes around nushell.sh aesthetic`):
  - New `--mc-bg` slate (#181a23) for dark, warm cream (#fbf6ec) for light; primary becomes nushell green (`#4eb960` / `#1a7f5a`), coral hotkey accent (`#f7768e` / `#c2410c`).
  - New `--mc-type-*` tokens (string/number/bool/null/date/filesize/key/error) for shell-style typed values; same names across themes.
  - New `--mc-font-sans` + `--mc-font-mono` split: chrome reads sans, terminal pane and tabular data explicitly switch to mono.
  - Dropped CRT scanline gradient on `.terminal-app` and `.login-shell`.
  - Subtle 2px gradient accent line under the menubar (border → type-key → hotkey).
  - Logo gets `>` prompt prefix and divider; `.mc-context` renders as a chip; menu items use sans body + mono hotkey letter; footer buttons get matching treatment.
  - Gateway login + assistant chat surfaces now flow entirely through theme tokens (previously hardcoded white/grey, looked off in dark mode).

## Repos
- `repos/noetl`: deployed image `ghcr.io/noetl/noetl:v2.24.2` (gitlink `f4c221af`, no change).
- `repos/gui`: deployed image `ghcr.io/noetl/gui:v1.1.2` (gitlink `311ff96`, no change). Topic branch `kadyapam/nushell-themes` pushed at `4276931` for review.
- `repos/e2e`: deployed catalog already includes the patched `test_mds_batch_worker` v7 (registered earlier in the session).
- `repos/ops`: ops playbooks unchanged at `58db847`.

## Open follow-ups
- Open a PR for `noetl/gui` `kadyapam/nushell-themes` and iterate on the theme based on visual review (dark + light side-by-side).
- After PR merges, bump the `repos/gui` gitlink in ai-meta with a `chore(sync)` commit (use `BumpPointers.app`).
- Track execution `615068195786850757` to terminal state; if it hits the same worker-pool-driven `command.failed` cluster around facility 4 like the previous run, scale up the worker pool first (3 ready × capacity 1 is too tight for `run_mds_batch_workers` `max_in_flight=5`). Suggested: edit the `noetl-worker` deployment to `replicas=5` or bump per-worker capacity.
- Open the two follow-up `noetl/noetl` issues already tracked in current.md: (a) sub-execution top-level status not transitioning to COMPLETED after `end` step finishes when parent advances via `call.done`, (b) empty-error `command.failed` cluster on `run_mds_batch_workers` under low worker capacity.

## Related
- DeployToKind.app + SmokeTest.app + StatusCheck.app launchers in `scripts/` (sweep with `rm -rf scripts/{Pull,Bump,DeployToKind,SmokeTest,StatusCheck}*.app scripts/*.log scripts/*_chmod_test scripts/*_command*` once you're done with them).
- Inbox `memory/inbox/2026/04/20260428-144406-bumped-e2e-gui-pointers-after-prs-merged.md` (pre-redeploy bumps).
- Inbox `memory/inbox/2026/04/20260428-114722-pft-clean-rerun-mds-end-fix-validated-fac-1-and-2-ok.md` (initial MDS fix validation).
- ai-meta heads since this session began: `9faf15b ae40e0b c2dfc22 a2c0159 4d45ac1 0fb4c76 699f66d 1c86b24` (push pending after this commit).
