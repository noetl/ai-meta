# Travel render bubble still AMBER — final tail cannot see selected render
- Timestamp: 2026-05-09T06:58:00Z
- Author: Codex
- Tags: ai-os,travel-agent,widgets,amber,execution-result,tail-step,gui,ops

## Summary
Codex processed bridge task `20260509-063112-travel-bubble-render-and-canvas-amber-to-green` and landed the planned GUI fix plus the initial ops tail-bubble fix. GUI PR noetl/gui#30 merged (`d8bdd2b`) and released `v1.10.1`; local GUI was deployed to `ghcr.io/noetl/gui:v1.10.1`. Ops PR noetl/ops#53 merged (`95068b2`) and a follow-up amendment PR noetl/ops#54 merged (`3a4c6c2`) after smoke showed the first tail step was losing branch payloads at the quoted Jinja/Python boundary. Travel runtime was re-registered as version 7 (`catalog_id=622787345497981057`).

## Important Finding
The round remains AMBER. Prompt smoke execution `622787485059252354` completed, and `render_help.render` was present in step variables, but the final `end` step still had `render=null`, `text=""`, `summary=""`, and `intent=null`. That means `execution.result.render` is still empty, so the GUI auto-render watcher and `report` command still have nothing reliable to show. The issue is deeper than simply replacing a noop tail: the final tail after `persist_and_callback` is not successfully recovering the earlier branch render payload.

## GUI/Deploy Notes
The `/travel` canvas header now references `automation/agents/travel/runtime`, so the stale `api_integration/amadeus_ai_api` hardcode is fixed in the deployed GUI. The local GUI deployment path also exposed an ops mismatch: `automation/development/gui.yaml` and the Helm chart default/adopt namespace `gui`, while the existing local NodePort GUI lives as a non-Helm-owned deployment/service in namespace `noetl`. Codex used a narrow `kubectl set image` fallback to move the existing deployment to the released public image.

## Next Move
Do not keep layering final-tail recovery on top of `persist_and_callback`. The cleaner next design is to make the persistence/callback step pass-through: receive the immediate previous render result, perform audit/callback, and return that same render payload as the final execution result. Another option is branch-specific final tails that reconstruct the render payload directly. After `execution.result.render` is truly populated, rerun prompt help/flights/locations, `/travel` canvas, and Amadeus MCP regression.
