# Handed travel Anthropic model flip to Codex (Path A — minimum diff to GREEN)

- date: 2026-05-11T05:00:00Z
- tags: travel-agent, anthropic, model-access, surgical-fix, amber-to-green, codex-handoff

## Round goal

Flip the hardcoded Anthropic model from `claude-3-5-haiku-latest` to a
current Haiku that the user's key has access to. Re-smoke. Close v2 AMBER
to GREEN.

## Why this round exists

The v2 re-smoke (`bridge/outbox/20260511-000500-travel-anthropic-resmoke-v2.result.json`)
closed AMBER with a clean diagnosis: secret + IAM correct, model name 404.
Direct probes in v2:
- claude-3-5-haiku-latest    → 404 not_found_error
- claude-3-5-haiku-20241022  → 404 not_found_error
- claude-sonnet-4-20250514   → 200

The user's API key is bound to a current model tier; the legacy 2024 Haiku
aliases have been retired or aren't enabled on this account.

## Path A vs Path B

Two ways to fix this:

**Path A (this round)** — surgical model-name flip in the hardcoded
`_anthropic_text` helper. One-line ops change. Fastest path to GREEN.

**Path B (deferred follow-up)** — lift Anthropic + OpenAI model names
into workload fields (`anthropic_model`, `openai_model`). Mirrors what
Phase 3/4 did for `vertex_model`/`ollama_model` and what item #9 did
for `classifier_system_prompt`. Pays parallel architectural debt that's
been sitting next to the prompt-debt the whole arc.

Path A first because it gets Anthropic shipping. Path B can be a small
follow-up round once GREEN.

## Probe candidates in cost order

1. `claude-haiku-4-5-20251001` — latest Haiku per Anthropic's May 2026
   lineup. Preferred for classification cost.
2. `claude-haiku-4-5` — mutable alias if it exists.
3. `claude-3-5-haiku-20241022` — legacy 2024 (already known 404; sanity
   check that it's actually retired vs key-restricted).
4. `claude-sonnet-4-20250514` — already known 200, fallback if no Haiku
   accessible. Note ~12x classification cost.

First 200 wins.

## Phases (5)

1. Probe candidates; pick the cheapest accessible one.
2. Apply model flip (single line edit in classify_via_http_provider's
   _anthropic_text helper).
3. Ops PR.
4. Re-register + 5-intent anthropic smoke matrix + spot-check regressions.
5. ai-meta pointer bump. Stage but do not push.

## Cap

1 ops PR.

## Bridge artefacts

- `bridge/inbox/delegated/20260511-050000-travel-anthropic-model-flip.task.json`
- `scripts/travel_anthropic_model_flip_msg.txt`

## Hard constraint: sanitise the key

The probe phase reads the API key from GCP. NEVER echo full key in result
file or screenshots. First 20 chars max for verification. Same convention
the v2 round followed.

## What's next after this lands

Path B (workload-field refactor for Anthropic + OpenAI model names) —
small follow-up round, mirrors the item #9 prompt single-source pattern.
Then the only remaining items are:

- Activities NoETL-reference hydration bug (item #11) — out of ops+docs scope
- Any new flagship arc the user wants to start
