# Inline-decision event-log visibility verified end-to-end on GKE; detector finding to investigate
- Timestamp: 2026-05-26T05:32:51Z
- Author: Kadyapam
- Tags: noetl,inline-execution,dry-run,verification,detector-bug,pr609

## Summary
PR #609 deployed to live GKE cluster (image inline-round-a-vis-20260526050818, Cloud Build 390e8f0c, Helm rev 162->163, all rollouts clean). Synthetic itinerary-planner execution 635063984781000752 completed in 10s. CONFIRMED: meta.inline_decision now lands in event log under result.context.meta.inline_decision; 12 events carry the decision (4 distinct agent steps × call.done/step.exit/command.completed each). Visibility loop closed end-to-end. INTERESTING FINDING from the real data: every firestore MCP call (load_slot_state, persist_turn_docs_atomically, append_turn_events_atomically, append_render_events_atomically) was marked inline=False with mode=allow_list, depth=0. Detector matched allow-list and passed framework/depth/steps/finalizer/callback/async/output_ref/loop/tenant checks. The blocker was tool:block:step[0].missing_tool_kind + tool:block:step[1].missing_tool_kind on EVERY decision. But repos/ops/automation/agents/mcp/firestore.yaml has only ONE workflow step (firestore_dispatch with tool.kind: python). The detector sees 2 steps neither with recognized tool.kind — discrepancy between the on-disk playbook and what the detector loads/parses via load_playbook_content + render_playbook_content. Real value: Round B can't usefully inline mcp/firestore until either the detector's child-playbook parsing is fixed OR the firestore playbook gets metadata.inline_when_safe: true with adjusted detector heuristics. This is exactly what the dry-run was designed to surface. ai-meta pointer bumps: repos/noetl fbc7716d -> bc8a1872, repos/noetl-wiki db4900fe -> dbf6c163. Wiki documents the persistence path under noetl/wiki/inline_execution#event-log-persistence. No follow-up handoff opened yet for the detector-strictness finding — it's bounded enough to drive directly when ready.

## Actions
-

## Repos
-

## Related
-
