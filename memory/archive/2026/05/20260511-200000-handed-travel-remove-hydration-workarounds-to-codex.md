# Handed travel runtime workaround cleanup to Codex (post-v2.37.8 belt-and-suspenders removal)

- date: 2026-05-11T20:00:00Z
- tags: travel-agent, cleanup, post-v2.37.8, workaround-removal, codex-handoff

## Round goal

Remove `_fetch_vertex_child_context` and `_fetch_ollama_child_context` from
the travel runtime's classifier merger. These helpers were necessary
before noetl v2.37.8 because the agent executor's envelope.data was sourced
from the truncated `/status` doc. As of v2.37.8 + the GKE smoke at
execution 624795118960115887 (10 items via render_activities), the engine
itself hydrates envelope.data from events. The workarounds are now
belt-and-suspenders — same behavior, more code to maintain.

## Why this round exists

The MinIO-elimination GKE rollout round just proved engine hydration works
end-to-end:
- Pre-stage object via boto3 inside worker pod, ETag captured.
- Kill noetl-worker pods, rollout restart.
- Re-fetch — ETag/SHA matched.
- Travel activities execution rendered 10 items via render_activities (the
  engine-hydrated path), not render_amadeus_failure.

That's the proof that v2.37.8's `_fetch_sub_execution_terminal_result` in
the agent executor does the work the travel runtime workarounds used to
do. Time to remove the redundancy.

## Scope is bounded

What changes:
- DELETE `_fetch_vertex_child_context` function definition in the merger.
- DELETE `_fetch_ollama_child_context` function definition.
- Replace caller usage with direct `envelope.get('data', {})` access.

What stays:
- `classify_via_vertex_mcp` + `classify_via_ollama_mcp` step definitions.
- `_extract_*_text_from_context` helpers (chat_completion envelope normalization).
- `render_*` steps (already read envelope.data).
- The engine hydration helper in noetl (`_fetch_sub_execution_terminal_result`).

Expected diff: ~40-80 lines smaller travel runtime.

## Five phases

1. Audit + design (grep workaround references, document call sites).
2. Apply removal + Pydantic-validate.
3. Smoke all four providers + the critical GKE activities regression test.
4. Grep invariant (both workaround names → 0 occurrences).
5. Ops PR + ai-meta pointer bump (stage, don't push).

## Cap

1 ops PR. No docs, gui, noetl, or e2e changes.

## Bridge artefacts

- `bridge/inbox/delegated/20260511-200000-travel-remove-hydration-workarounds.task.json`
- `scripts/travel_remove_hydration_workarounds_msg.txt`

## Trigger prompt for Codex (paste this in after pushing)

```
Post-v2.37.8 cleanup. Remove _fetch_vertex_child_context + _fetch_ollama_child_context
workarounds from the travel runtime — the engine hydration in v2.37.8 makes
them redundant. GKE smoke 624795118960115887 already proved engine hydration
works end-to-end (10 items via render_activities, not friendly failure).

Bridge task: bridge/inbox/delegated/20260511-200000-travel-remove-hydration-workarounds.task.json
Prompt details: scripts/travel_remove_hydration_workarounds_msg.txt
Result file: bridge/outbox/20260511-200000-travel-remove-hydration-workarounds.result.json

Run all 5 phases per the bridge task:
  1. Audit + design (grep, document call sites).
  2. Apply removal — delete both helper functions, replace callers with
     envelope.get('data', {}) direct reads. Pydantic-validate.
  3. Smoke all four providers + critical GKE activities regression
     (`travel --provider vertex-ai activities near Times Square` on GKE).
     Spot-check engine hydration via noetl status events.
  4. Grep invariant: both workaround names → 0.
  5. Ops PR + ai-meta pointer bump (stage, don't push).

Architectural rules:
  - Ops only round. No noetl, gui, docs, e2e changes.
  - Don't touch the engine hydration helper in repos/noetl — load-bearing.
  - Don't modify classify_via_*_mcp step definitions, only the merger's
    text-extraction path.
  - Keep the _extract_*_text_from_context helpers — they still normalize
    chat_completion envelope shape.
  - No release cut. No git push from ai-meta.

What to do if blocked:
  - Pydantic fails post-removal: transitive consumers Claude's audit missed
    → document + AMBER + STOP.
  - Smoke regresses: roll back PR + AMBER + STOP, capture audit row diff.
```

## What's left after this lands

Three explicit deferreds remain, all genuinely optional:

1. **14th authoring-guide rule** pinning the kind→GKE parity process lesson.
   Three rediscoveries in the session is strong signal.
2. **Cloud-tier router decision** — GCS vs in-cluster S3 vs remote AWS S3
   for durable storage beyond the in-cluster object-store chooser.
3. **Ollama bridge deployment on GKE** if real Ollama inference is wanted
   (currently falls back to OpenAI on GKE).
4. **Amadeus production API switch** when production-data smokes are wanted.

After this cleanup round closes, the travel agent is at its leanest possible
state — a thin dispatcher with no hydration concerns, around two MCP
playbooks (Amadeus + Vertex + Ollama), with the engine doing the heavy lifting.
