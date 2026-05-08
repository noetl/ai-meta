# noetl render projection allow-path round 2 unblock
- Timestamp: 2026-05-08T17:45:55Z
- Author: unknown
- Tags: ai-os,round-2,unblock,noetl,worker,projection,event-source,allow-path,red-to-green,bridge,codex,handoff

## Summary
Round 2 widget renderer deploy went RED — Codex shipped GUI v1.8.0 + docs cleanly, local kind rolled out, but synthetic widget smokes (executions 622377612446270148 and 622377613679395529) persisted only render.type. The noetl worker projection at noetl/worker/nats_worker.py:_extract_control_context strips dict-typed children unless an explicit allow-path exists. The function already has one for error.diagnosis (noetl#417 v2.37.1 sha 4a4f9f6); none for render. Claude added the symmetric carve-out: when key_str=='render' and child.get('args') is dict-or-list, _preserve_recursive_control_value(child['args']) rescues the nested widget tree under the same max_depth=8 guard. Render.type still survives via the existing scalar collector — only the new branch restores args. Added 5 tests mirroring the 4 error.diagnosis tests: nested-tree, unknown-type, depth-guard, type-only, list-typed-args. Fix logic verified inline in sandbox (5/5 assertions pass; full pytest deferred to Codex since noetl deps aren't in sandbox). Bridge task bridge/inbox/delegated/20260508-074315-noetl-render-projection-allow-path.task.json hands deploy/replay/pointer-bump to Codex with 5 phases: pytest → noetl PR → local kind redeploy via repos/ops/automation/development/noetl.yaml → replay both smokes to GREEN with browser screenshots → ai-meta pointer bump (staged). Codex prompt at scripts/render_projection_allow_path_msg.txt. Sync issue 2026-05-08-noetl-as-ai-os-token-architecture.md gained a Round 2 deployment notes section. NOTE: GUI v1.8.0 ships ~191 KB gzip over the 60 KB threshold — Codex flagged it as a follow-up; lazy-loading heavier widgets is a separate round-2.x cleanup.

## Actions
-

## Repos
-

## Related
-
