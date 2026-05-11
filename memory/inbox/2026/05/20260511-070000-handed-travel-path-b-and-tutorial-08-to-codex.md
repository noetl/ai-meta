# Handed travel Path B + tutorial 08 to Codex (final architectural-purity round + ship docs)

- date: 2026-05-11T07:00:00Z
- tags: travel-agent, path-b, model-workload-fields, tutorial-08, gui-walkthrough, codex-handoff

## Round goal

Two genuinely independent pieces bundled into one round:

(1) **Path B**: lift `openai_model` and `anthropic_model` into workload
    fields. Mirror the item #9 classifier_system_prompt single-source
    pattern. After this lands, every provider's model name is workload-
    overridable. Final symmetry achieved: prompt + all four model names
    are caller-tunable.

(2) **Tutorial 08 shipping**: Kadyapam pre-wrote a screenshot-led GUI
    walkthrough (`08-travel-agent-gui-walkthrough.md`), updated 07 to
    link it, cross-linked from widgets.md, and added screenshots. All
    four changes sit uncommitted in repos/docs. Codex ships them via a
    docs PR — does NOT author content.

Each piece gets its own PR (one ops + one docs), shared regression
smoke matrix at close-out.

## Path B refactor

Workload additions:
- `openai_model: "gpt-4o-mini"` (default — current)
- `anthropic_model: "claude-haiku-4-5-20251001"` (default — post item #5b)

classify_via_http_provider's `input` block gains:
- `openai_model: "{{ workload.openai_model }}"`
- `anthropic_model: "{{ workload.anthropic_model }}"`

Inside the Python helpers:
- `_openai_text`: hardcoded `"model": "gpt-4o-mini"` → `"model": openai_model`
- `_anthropic_text`: hardcoded `"model": "claude-haiku-4-5-20251001"` → `"model": anthropic_model`

Grep invariants verify (gpt-4o-mini once in workload, claude-haiku-4-5
once in workload, both workload.X references ≥ 1).

## Tutorial 08 — Codex's hands-off job

The docs work is finished — Codex just commits, PRs, merges.

Files (per Kadyapam's handoff):
- docs/tutorials/08-travel-agent-gui-walkthrough.md (NEW)
- docs/tutorials/07-travel-agent-with-widgets.md (UPDATED — link to 08,
  refresh "What's next")
- docs/gui/widgets.md (UPDATED — cross-link to 08)
- static/img/tutorials/travel-agent/*.png (NEW screenshots)

The denied_tools list forbids modifying Kadyapam's content. ONE optional
exception allowed: if tutorial 08 or 07 mentions the OpenAI/Anthropic
model name inline, Codex may add a one-paragraph note about workload
model overrides (mirrors the prompt-override paragraph from item #9).
Only if existing text naturally invites it.

## Why bundled in one round

Path B and tutorial 08 are independent. Neither blocks the other. Two
PRs in parallel is the natural shape. Smoke matrix at close-out covers
both — Path B regression (no classifier drift), tutorial 08 build
verification.

If sequencing mattered, this would split into two rounds. It doesn't,
so one round is cleaner bookkeeping.

## Free side benefit of Path B

After this lands, callers can override ANY provider's model via workload
payload:

```yaml
# OpenAI: bump to the more capable gpt-4o for a domain-specific test
workload:
  ai_provider: openai
  openai_model: gpt-4o

# Anthropic: try a different Haiku variant
workload:
  ai_provider: anthropic
  anthropic_model: claude-haiku-3-5-20241022
```

No playbook fork, no classifier code change. Same caller-override pattern
the vertex_model and ollama_model fields already provide.

## Phases (5)

1. Apply Path B refactor + grep verification.
2. Path B ops PR.
3. Ship tutorial 08 docs PR.
4. Re-register + 4-provider regression smoke matrix + optional override probe.
5. ai-meta pointer bumps for ops + docs. Stage but do not push.

## Bridge artefacts

- `bridge/inbox/delegated/20260511-070000-travel-path-b-and-tutorial-08.task.json`
- `scripts/travel_path_b_and_tutorial_08_msg.txt`

## What's actually left after this lands

Just two items, both out of "ops + docs" scope or future-gated:

1. **Activities NoETL-reference hydration bug** — lives in repos/noetl
   engine code. Affects all agent → MCP hops with large payloads.
   Surfaced from item #7. Needs a noetl-engine round.

2. **Amadeus production API switch** — confirmed test API has external
   500s (item #7 verdict b). Friendly-error widget masks gracefully today.
   Future round when production-data smokes are wanted.

The travel agent is feature-complete after Path B lands. Tutorial 08
ships as the screenshot-led GUI walkthrough closing the docs loop.

## Trigger prompt for Codex (paste this in after pushing)

```
Two independent pieces in one round:

(1) Path B — lift openai_model and anthropic_model into workload fields.
    Mirrors item #9 classifier_system_prompt single-source pattern.

(2) Tutorial 08 GUI walkthrough — Kadyapam pre-wrote it, sits uncommitted
    in repos/docs. Codex ships the user's content, does NOT author.

Bridge task: bridge/inbox/delegated/20260511-070000-travel-path-b-and-tutorial-08.task.json
Prompt details: scripts/travel_path_b_and_tutorial_08_msg.txt
Result file: bridge/outbox/20260511-070000-travel-path-b-and-tutorial-08.result.json

Run all five phases per the bridge task: apply Path B → ops PR → ship
tutorial 08 docs PR (don't modify content) → re-register + 4-provider
regression smoke matrix → ai-meta pointer bumps (stage, don't push).

Architectural rules: don't modify MCP playbooks, classifier merger,
render_* steps, or Kadyapam's tutorial 08/07/widgets.md content beyond
the optional one-paragraph model-override note. Don't touch the
unrelated untracked memory file in ai-meta. No git push from ai-meta.
```
