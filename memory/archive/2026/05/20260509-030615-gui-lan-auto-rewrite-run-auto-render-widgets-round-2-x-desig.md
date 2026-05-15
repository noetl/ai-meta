# GUI LAN auto-rewrite + run auto-render widgets — round 2.x design + handoff
- Timestamp: 2026-05-09T03:06:15Z
- Author: unknown
- Tags: ai-os,round-2x,lan-access,gui,auto-render,widgets,bridge,codex,handoff

## Summary
Codex's handover at bridge/outbox/20260509-025240-widget-lan-handover-to-claude.md surfaced two GUI usability gaps after round 2 GREEN: (a) helm-chart-baked VITE_API_BASE_URL=http://localhost:8082 fails from another LAN client because the client browser resolves localhost to itself; Codex band-aided with kubectl set env, every redeploy undoes that. (b) User asked 'playbook executing but how would I see widgets?' — round 2 left widgets behind explicit `report <execution_id>`. Claude designed both fixes GUI-only and shipped them in working tree (not committed). Fix A: repos/gui/src/services/gatewayBaseUrl.ts gains rewriteLocalhostForLan(envValue, pageHostname) — rewrites only when env URL has localhost hostname AND page is loaded from non-localhost host; preserves scheme + port; single-machine dev and production gateway.<domain> flows untouched. Inline-tested 7/7 cases pass (Node URL parsing). Fix B: repos/gui/src/components/NoetlPrompt.tsx gains watchExecutionForRender(executionId, label) — polls every second up to 60s; when execution terminates with extractAgentRender returning a render payload, appends a fresh prompt entry with the rendered widget. Wired into verb==='run' — started entry now gets report+open action buttons too. Fire-and-forget; non-render playbooks don't pollute the prompt. tsc --noEmit clean. Bridge task bridge/inbox/delegated/20260509-030314-gui-lan-rewrite-and-run-auto-render.task.json hands 7 phases to Codex: typecheck+build, gui PR (kadyapam/lan-rewrite-and-run-auto-render, expect semantic-release v1.9.0 since feat), restart Podman+kind (disconnected at end of prior session), redeploy gui WITHOUT re-applying the kubectl-set-env workaround (we want to verify auto-rewrite), LAN smoke from a different LAN machine (DevTools should show env still localhost but Network requests going to LAN IP), auto-render smoke (run with widget playbook → widget appears in prompt without typing report; run without render → no spurious entry), ai-meta gitlink bump on top of existing 7 unpushed commits. Codex prompt at scripts/gui_lan_rewrite_and_run_auto_render_msg.txt. Sync issue 2026-05-08 gained a 'Round 2.x — LAN-routable API base + post-run widget visibility' section. Helm chart left as-is for forward-compat; a future round can flip the default to empty so GUI derives entirely from window.location, but that's a separate chart PR.

## Actions
-

## Repos
-

## Related
-
