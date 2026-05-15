# Round 2.x GREEN — GUI LAN auto-rewrite + run auto-render shipped
- Timestamp: 2026-05-09T04:19:16Z
- Author: unknown
- Tags: ai-os,round-2x,green,close-out,gui,lan-access,auto-render,widgets,milestone

## Summary
Round 2.x closed GREEN. Two PRs in noetl/gui: #27 (kadyapam/lan-rewrite-and-run-auto-render, released v1.9.0) and #28 (follow-up: prompt run was sending version: 'latest' and /api/execute rejected it with 422; fix passes the resolved catalog version, released v1.9.1). Local kind running ghcr.io/noetl/gui:v1.9.1 Ready 1/1, with VITE_API_BASE_URL=http://localhost:8082 still baked into runtime env (no kubectl-set-env band-aid) — the LAN rewrite was tested rather than bypassed. Smoke evidence: LAN URL http://192.168.1.240:30081/catalog reachable from another LAN client without Network Error; API calls route to LAN host through the auto-rewrite. Widget auto-render execution 622695138808038281: rendered widget appeared in prompt history in about 4s after run completion (no `report <execution_id>` typed). Button callback emitted echo widget-button-command (handleWidgetEvent intercepted key=='command'). Non-render execution 622695484049589148 completed without spurious widget output (the watcher silently gives up after 60s). Codex result file at bridge/outbox/20260509-030314-gui-lan-rewrite-and-run-auto-render.result.json; codex memory entry at memory/inbox/2026/05/20260509-034656-gui-lan-auto-render-green.md; validation log appended. ai-meta pointer bumped to repos/gui 2659d7b / v1.9.1 (10 unpushed commits as of close-out). Lessons: the v1.9.0 cut hit a 422 on the run path because executePlaybookWithPayload was sending version='latest' literally, which /api/execute rejects — the fix resolves the catalog version first. Inline TS test didn't catch it because the LAN-rewrite tests didn't exercise run; the smoke surfaced it. Round 3 (terminal-window unification with token cursor) and round 2.x deferred items (extractAgentRender in mcp/k8s/call paths, app:form values feeding run payloads, lazy-load heavier widgets to walk back the +191 KB gzip delta, helm chart flip to VITE_API_BASE_URL='') remain open.

## Actions
-

## Repos
-

## Related
-
