# Travel canvas widget rerun GREEN
- Timestamp: 2026-05-09T15:51:38Z
- Author: Codex
- Tags: ai-os,travel-agent,gui,widgets,canvas,green,local-kind

## Summary
Codex closed the remaining travel canvas widget rerun AMBER. Two GUI fixes landed: noetl/gui#32 (`c79ae3001550c966b79c9dc465e01008c2842413`, release `v1.10.3`) stores `sourcePrompt` on assistant messages and maps widget `command` events such as `rerun <execution_id>` back to the original travel query; noetl/gui#33 (`38c00ae58979d3e62bfb68345eedffd44d8c24d6`, release `v1.10.4`) makes `AppButton` consume DOM clicks with `preventDefault()` and `stopPropagation()` before emitting widget events. Local kind now runs `ghcr.io/noetl/gui:v1.10.4`.

## Evidence
Final browser smoke on `/travel?final-rerun=v1104-1778341683024` submitted `flights from SFO to JFK on 2026-07-15 for 2 adults`, rendered the friendly-error widget, clicked the scoped canvas `rerun this search` button, stayed on `/travel`, and produced a fresh rerun execution `623060323385213862`. The widget count increased, the original query remained visible, and loading cleared. This closes the canvas part of the travel flagship arc.

## Notes
The release-triggered `v1.10.4` image workflow stalled in Docker build/push and was cancelled after about 25 minutes; the same versioned image build was rerun via workflow_dispatch for tag `v1.10.4` and completed successfully. `bump_image` reported the known completed-old-pod sampling mismatch, but explicit `kubectl rollout status` and pod image checks confirmed the running GUI pod uses `ghcr.io/noetl/gui:v1.10.4`.
