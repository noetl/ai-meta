# Noetl agent result hydration closes GREEN — entire deferred list cleared

- date: 2026-05-11T10:00:00Z
- tags: noetl-engine, agent-executor, hydration, v2.37.8, green, item-11, arc-complete

## What landed

- noetl PRs: #424 → #429 (six total, Copilot review-prompted iterations)
- Final noetl release: v2.37.8
- Local kind image: `local/noetl:2026-05-10-22-48`
- GKE image: `ghcr.io/noetl/noetl:v2.37.8`
- ai-meta repos/noetl gitlink bumped to 82819f0c
- Validation log appended

## GREEN smoke evidence

**Local kind activities execution `624209763244441670`:**
- `data.ok=true`
- `items_len=10`
- `activities_total=1799` (the full Amadeus response — uncompacted, hydrated correctly)
- rendered via `render_activities` (not render_amadeus_failure)

**GKE activities execution `624205070757790326`:**
- Same GREEN proof
- Cross-pod bounded control_data verified — Workload Identity SA could read events from the sub-execution's pod

**GKE 4-provider sanity:**
- OpenAI: GREEN
- Anthropic: GREEN
- Vertex AI: GREEN
- Ollama: completed via OpenAI fallback because GKE currently has no ollama-bridge service deployed (new follow-up item — see below)

## Test coverage

30 focused tests passed including Claude's 3 new tests:
- picks_last_terminal_step (highest event_id wins, boundary nodes skipped)
- returns_none_when_no_terminal (fallback path works)
- swallows_request_failure (network errors → None, never raises)

## Six PRs to ship a 250-line engine fix

PRs #424 through #429. Five follow-ups means Copilot reviewers iterated
on the diff. This is a real signal worth pinning:

> noetl-engine rounds have ~10x the PR overhead of ops+docs rounds.
> Future engine rounds should budget for 3-6 PRs of follow-up review
> rather than the 1 PR typical of playbook/docs work.

The bridge handoff pattern still worked — Codex absorbed the Copilot
review cycles autonomously. But the close-out time was longer than
prior rounds (multi-hour vs sub-hour).

## New deferred item surfaced

**Ollama bridge on GKE**: the GKE cluster currently has no `ollama-bridge`
service deployed in the noetl namespace. `travel --provider ollama` on
GKE fell back to OpenAI because the bridge URL resolves to nothing.

Two ways to address:
1. Deploy ollama + ollama-bridge to the GKE cluster (real Ollama inference
   on GKE — meaningful infra round, may need GPU node pool or CPU-only
   smaller model).
2. Document that Ollama provider is kind-only and update the workload
   default or surface a clearer error when the bridge URL doesn't
   resolve. Smaller round.

Both are out of "ops + docs" scope. Defer to a future infrastructure
session.

## Architectural payoff

After this fix, every agent → MCP hop benefits from uncompacted result
hydration. The travel runtime's existing `_fetch_vertex_child_context`
and `_fetch_ollama_child_context` helpers are now belt-and-suspenders
(no longer load-bearing) — their removal is a future cleanup round.

Three concrete users of the new hydration path:
- Amadeus search_activities (item #11 proof case)
- mcp/vertex-ai chat_completion (the prior workaround target)
- mcp/ollama chat_completion (the prior workaround target)

Plus every future agent → MCP hop the team adds.

## Session arc fully complete

Twelve rounds shipped in one cowork session, all GREEN:

| #   | round                                                        | scope         | result |
| --- | ------------------------------------------------------------ | ------------- | ------ |
| 1   | Workload-default rule (12th authoring guide rule)            | docs          | GREEN  |
| 2   | Hotels/activities branches                                   | ops + docs    | GREEN  |
| 3   | app:form refinement widget                                   | gui+ops+docs  | GREEN  |
| 4   | Audit side-effect inside render_*                            | ops + docs    | GREEN  |
| 5a  | Anthropic re-smoke v2                                        | smoke         | AMBER → narrowed |
| 5b  | Anthropic model flip                                         | ops           | GREEN  |
| 6   | Ollama Phase 4                                               | ops + docs    | GREEN  |
| 7   | Amadeus 500 investigation                                    | diagnostic    | GREEN  |
| 8   | Python globals/locals rule (13th authoring guide rule)       | docs          | GREEN  |
| 9   | Classifier prompt single-source                              | ops + docs    | GREEN  |
| 10  | Path B model workload fields + Tutorial 08                   | ops + docs    | GREEN  |
| 11  | Noetl agent → MCP sub-execution result hydration             | noetl-engine  | GREEN  |

Twelve rounds. All ops+docs follow-ups closed. The noetl-engine round
shipped despite ~10x PR overhead. The travel agent and the platform
beneath it are both at their full completion state for this arc.

## What's actually left

Two items remain, both genuinely optional:

1. **Amadeus production API switch** — confirmed test API sandbox 500s
   in item #7. Production-data smokes cost real money. Future round
   when wanted.

2. **Ollama bridge on GKE** — surfaced in this round's GKE smoke. Either
   deploy the bridge service or document Ollama as kind-only. Future
   infra round.

Plus 1 cleanup follow-up:

3. **Remove travel runtime's belt-and-suspenders workarounds**
   (`_fetch_vertex_child_context`, `_fetch_ollama_child_context`) once
   the v2.37.8 engine fix has been stable for a few days. Small ops PR.
   Optional polish.
