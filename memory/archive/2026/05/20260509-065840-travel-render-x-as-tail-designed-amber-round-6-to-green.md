# Travel render_X-as-tail designed — AMBER round 6 to GREEN
- Timestamp: 2026-05-09T06:58:40Z
- Author: unknown
- Tags: ai-os,flagship,travel-agent,amber-to-green,workflow-tail,noetl-scope,bridge,codex,handoff,design-pattern

## Summary
Round 6 closed AMBER. Backend GREEN canvas wired. Trailing python end step that tried to bubble render via Jinja inputs did not work because NoETL variable scope from a tail step does not reliably see arbitrary upstream branch outputs after a sibling step has overwritten the output chain (persist_and_callback kind postgres clobbers result on the way to end). Codex diagnosis: stop trying to recover branch output from a final tail. Claude shipped restructure in working tree not committed: removed persist_and_callback send_callback and end entirely. Each render_* step (render_flights render_locations render_help render_amadeus_failure) is now the workflow tail for its branch with no next arcs. NoETL takes last step result as execution.result so execution.result.render is automatically the widget tree. Added doc comment before render_* steps explaining design rule: audit and callback are SIDE EFFECTS inside render_* python steps (psycopg urllib) when needed never trailing steps that overwrite result. Bridge task bridge/inbox/delegated/20260509-065650-travel-render-tail-amber-to-green.task.json hands 7 phases to Codex validate ops PR re-register terminal widget visibility (verify via noetl status jq result.render returns non-null app column) canvas smoke MCP regression ai-meta pointer bump on top of 29 unpushed commits. Codex prompt at scripts/travel_render_tail_amber_to_green_msg.txt. Lesson NoETL execution result is the LAST steps result; when last step is a sibling tool kind (postgres http) it overwrites whatever previous render-emitting step produced. Use render-emitting step as the workflow tail. If audit or callback needed do them as side effects inside the render-emitting python step not as trailing steps. This is worth pinning in architecture/agent_orchestration.md.

## Actions
-

## Repos
-

## Related
-
