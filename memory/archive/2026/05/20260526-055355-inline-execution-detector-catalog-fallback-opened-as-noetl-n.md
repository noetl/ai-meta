# Inline-execution detector catalog fallback opened as noetl/noetl#610
- Timestamp: 2026-05-26T05:53:55Z
- Author: Kadyapam
- Tags: noetl,inline-execution,detector,dry-run,bugfix,pr610

## Summary
Followed up on the dry-run finding from execution 635063984781000752: every mcp/firestore decision came back inline=false with tool:block:step[0].missing_tool_kind reasons. Root cause: noetl/core/workflow/playbook/loader.load_playbook_content falls back to create_placeholder_playbook() when the child isn't on the worker's local filesystem (always the case for cross-repo entrypoints like automation/agents/mcp/firestore which lives in noetl/ops). The stub has 2 steps (start, end) and no tool.kind, which the Round A detector correctly flags as un-inlineable. PR #610 (kadyapam/inline-detector-catalog-fallback, commit 2056f988): adds _looks_like_placeholder_playbook() exact-shape matcher + _load_inline_child_playbook_from_catalog() sync HTTP helper hitting POST /api/catalog/resource, wires the dry-run loader to fall through to the catalog when the local render returns the stub. 9 new tests, 30 total pass. Best-effort: failed catalog lookup keeps the placeholder so detector emits missing_tool_kind (correct outcome for genuinely un-inspectable children). No changes to detector logic, PR #608 dry-run wiring, PR #609 meta.inline_decision projection, or dispatch behavior. After this lands the dry-run signal becomes accurate against the production itinerary-planner workload — next probable improvement is metadata.inline_when_safe: true on firestore.yaml in noetl/ops to unlock inline=true decisions, leading into Round B.

## Actions
-

## Repos
-

## Related
-
